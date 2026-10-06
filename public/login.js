const form = document.getElementById("login-form");
const errorBox = document.getElementById("login-error");
const loginBtn = document.getElementById("login-btn");

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  errorBox.classList.remove("show");
  loginBtn.disabled = true;
  loginBtn.textContent = "Signing in...";

  const email = document.getElementById("email").value;
  const password = document.getElementById("password").value;

  // This is the line that actually talks to Supabase Auth.
  const { data, error } = await supabaseClient.auth.signInWithPassword({
    email,
    password,
  });

  if (error) {
    errorBox.textContent = "Incorrect email or password.";
    errorBox.classList.add("show");
    loginBtn.disabled = false;
    loginBtn.textContent = "Sign in";
    return;
  }

  // Signed in — send everyone to the dashboard.
  // dashboard.html will look up the signed-in user's role and show the
  // right view (cashier vs. manager).
  window.location.href = "dashboard.html";
});
