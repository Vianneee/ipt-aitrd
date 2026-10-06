-- Automated Inventory Tracking and Replenishment Dashboard
-- Database schema (Supabase / PostgreSQL)
-- Run in: Supabase Dashboard -> SQL Editor -> New query

create extension if not exists "pgcrypto"; -- gen_random_uuid()

-- =====================================================================
-- 1. TABLES
-- =====================================================================

-- Suppliers
create table suppliers (
  supplier_id   uuid primary key default gen_random_uuid(),
  name          text not null,
  contact_email text,
  contact_phone text,
  created_at    timestamptz default now()
);

-- Profiles (replaces the old "users" table)
-- Credentials (email + password hash) live in Supabase's own auth.users table.
-- This table only stores the app-specific info, keyed to the same id.
create table profiles (
  employee_id uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  role        text not null default 'cashier'
                check (role in ('cashier', 'manager', 'admin')),
  created_at  timestamptz default now()
);

-- Items (product + current inventory status)
create table items (
  item_id               uuid primary key default gen_random_uuid(),
  name                  text not null,
  sku                   text unique not null,
  category              text,
  unit_price            numeric(10, 2) not null default 0 check (unit_price >= 0),
  current_stock         integer not null default 0 check (current_stock >= 0),
  min_reorder_threshold integer not null default 0 check (min_reorder_threshold >= 0),
  standard_reorder_qty  integer not null default 0 check (standard_reorder_qty >= 0),
  location              text,
  supplier_id           uuid references suppliers(supplier_id) on delete set null,
  created_at            timestamptz default now()
);

-- Sales Transactions (Phase 2, Path B)
create table sales_transactions (
  transaction_id uuid primary key default gen_random_uuid(),
  item_id        uuid not null references items(item_id),
  employee_id    uuid not null references profiles(employee_id),
  sold_at        timestamptz not null default now(),
  quantity_sold  integer not null check (quantity_sold > 0),
  total_value    numeric(10, 2) not null check (total_value >= 0)
);

-- Stock Movements (Phase 2, Path A: receiving stock)
create table stock_movements (
  movement_id       uuid primary key default gen_random_uuid(),
  item_id           uuid not null references items(item_id),
  employee_id       uuid not null references profiles(employee_id),
  received_at       timestamptz not null default now(),
  quantity_received integer not null check (quantity_received > 0)
);

-- Alerts (Phase 3 creates them, Phase 4: manager review)
create table alerts (
  alert_id              uuid primary key default gen_random_uuid(),
  item_id               uuid not null references items(item_id),
  flagged_at            timestamptz not null default now(),
  status                text not null default 'pending'
                          check (status in ('pending', 'approved', 'dismissed')),
  reviewed_by           uuid references profiles(employee_id),
  suggested_reorder_qty integer check (suggested_reorder_qty >= 0),
  resolved_at           timestamptz
);

-- =====================================================================
-- 2. INDEXES
-- =====================================================================

-- The forecasting engine pulls "last 30 days of sales for one item"
create index idx_sales_item_date  on sales_transactions (item_id, sold_at desc);
create index idx_moves_item_date  on stock_movements (item_id, received_at desc);
create index idx_alerts_item_stat on alerts (item_id, status);
create index idx_items_supplier   on items (supplier_id);

-- Only ONE pending alert per item, so the engine can't spam duplicates
create unique index one_pending_alert_per_item
  on alerts (item_id) where status = 'pending';

-- =====================================================================
-- 3. AUTO-CREATE A PROFILE WHEN SOMEONE SIGNS UP
-- =====================================================================
-- New accounts always start as 'cashier'. Promote a manager manually:
--   update profiles set role = 'manager' where name = 'Your Name';
-- (Don't let the signup form choose the role, or anyone could make themselves admin.)

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into profiles (employee_id, name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    'cashier'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- =====================================================================
-- 4. FUNCTIONS THE BUTTONS CALL  (db.rpc('record_sale', {...}) etc.)
-- =====================================================================
-- Each one updates stock AND logs the transaction in a single step,
-- so the two can never get out of sync.

-- "Make a sale" button (Path B): deduct stock + log the sale
create or replace function record_sale(p_item_id uuid, p_quantity integer)
returns sales_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item items;
  v_sale sales_transactions;
begin
  if auth.uid() is null then
    raise exception 'You must be logged in';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0';
  end if;

  -- lock the row so two simultaneous sales can't oversell
  select * into v_item from items where item_id = p_item_id for update;
  if not found then
    raise exception 'Item not found';
  end if;
  if v_item.current_stock < p_quantity then
    raise exception 'Not enough stock: only % left', v_item.current_stock;
  end if;

  update items
     set current_stock = current_stock - p_quantity
   where item_id = p_item_id;

  insert into sales_transactions (item_id, employee_id, quantity_sold, total_value)
  values (p_item_id, auth.uid(), p_quantity, v_item.unit_price * p_quantity)
  returning * into v_sale;

  return v_sale;
end;
$$;

-- "Receive shipment" button (Path A): add stock + log the movement
create or replace function receive_stock(p_item_id uuid, p_quantity integer)
returns stock_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_move stock_movements;
begin
  if auth.uid() is null then
    raise exception 'You must be logged in';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0';
  end if;

  update items
     set current_stock = current_stock + p_quantity
   where item_id = p_item_id;
  if not found then
    raise exception 'Item not found';
  end if;

  insert into stock_movements (item_id, employee_id, quantity_received)
  values (p_item_id, auth.uid(), p_quantity)
  returning * into v_move;

  return v_move;
end;
$$;

-- =====================================================================
-- 5. HELPER VIEW FOR THE FORECASTING ENGINE + TREND GRAPHS
-- =====================================================================
-- Units sold per item per day (Manila time). The 7-day rolling average
-- velocity is just the average of the last 7 rows for an item.

create or replace view daily_sales
with (security_invoker = true) as
select
  item_id,
  (sold_at at time zone 'Asia/Manila')::date as sale_date,
  sum(quantity_sold)::integer                as units_sold
from sales_transactions
group by item_id, (sold_at at time zone 'Asia/Manila')::date;

-- =====================================================================
-- 6. ROW LEVEL SECURITY
-- =====================================================================
-- Login now goes through Supabase Auth, so only logged-in users
-- ("authenticated") get access. Anonymous visitors get nothing.

create or replace function is_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where employee_id = auth.uid()
      and role in ('manager', 'admin')
  );
$$;

alter table suppliers          enable row level security;
alter table profiles           enable row level security;
alter table items              enable row level security;
alter table sales_transactions enable row level security;
alter table stock_movements    enable row level security;
alter table alerts             enable row level security;

-- Everyone logged in can read everything (needed for the dashboard)
create policy "read suppliers" on suppliers          for select to authenticated using (true);
create policy "read profiles"  on profiles           for select to authenticated using (true);
create policy "read items"     on items              for select to authenticated using (true);
create policy "read sales"     on sales_transactions for select to authenticated using (true);
create policy "read movements" on stock_movements    for select to authenticated using (true);
create policy "read alerts"    on alerts             for select to authenticated using (true);

-- Phase 1: any logged-in user can add a new product (cashier or admin, per the flowchart)
create policy "add items" on items for insert to authenticated with check (true);

-- Only managers/admins can edit product details or manage suppliers
create policy "edit items"      on items     for update to authenticated using (is_manager()) with check (is_manager());
create policy "manage suppliers" on suppliers for all    to authenticated using (is_manager()) with check (is_manager());

-- Phase 3: the forecasting engine (runs in the browser) creates alerts
create policy "create alerts" on alerts for insert to authenticated with check (status = 'pending');

-- Phase 4: only managers/admins can approve or dismiss, and must record themselves as reviewer
create policy "review alerts" on alerts for update to authenticated
  using (is_manager())
  with check (is_manager() and reviewed_by = auth.uid());

-- No insert/update policies on sales_transactions or stock_movements on purpose:
-- they can only be written through record_sale() and receive_stock() above.

-- Let logged-in users call the button functions (and nobody else)
revoke execute on function record_sale(uuid, integer)   from public, anon;
revoke execute on function receive_stock(uuid, integer) from public, anon;
grant  execute on function record_sale(uuid, integer)   to authenticated;
grant  execute on function receive_stock(uuid, integer) to authenticated;