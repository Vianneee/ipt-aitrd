// Shared Supabase client — every page includes this file first.
//
// Replace these two values with your actual project's credentials:
// Supabase Dashboard -> Project Settings -> API
const SUPABASE_URL = "https://qsuyxghhtgtayfosqhee.supabase.co";
const SUPABASE_KEY = "sb_publishable_h98KRdaNnQ9zq7wnHHQIQw_y8HMU-WI";

const supabaseClient = window.supabase.createClient(
  SUPABASE_URL,
  SUPABASE_KEY
);

// Helper used by every protected page (items, transactions, dashboard)
// to bounce back to login if no one is signed in.
async function requireLogin() {
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) {
    window.location.href = "login.html";
    return null;
  }
  return session;
}
