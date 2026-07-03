// hydra-worker desktop frontend. Calls the Rust #[tauri::command] handlers via the global
// Tauri bridge (app.withGlobalTauri = true). Never stores or echoes a raw token.

const invoke = window.__TAURI__.core.invoke;
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function toast(msg, bad = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.toggle("bad", bad);
  t.classList.remove("hidden");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add("hidden"), 3200);
}

async function call(cmd, args) {
  try {
    return await invoke(cmd, args);
  } catch (e) {
    toast(typeof e === "string" ? e : JSON.stringify(e), true);
    throw e;
  }
}

// ---- Unlock ----
$("#unlock-btn").addEventListener("click", async () => {
  const passphrase = $("#pass").value;
  if (!passphrase) return toast("enter a passphrase", true);
  await call("unlock", { passphrase });
  $("#gate").classList.add("hidden");
  $("#console").classList.remove("hidden");
  await loadConfig();
  await refreshProviders();
  startStatusPolling();
});
$("#pass").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("#unlock-btn").click();
});

// Reset the vault from the gate (e.g. a lost/forgotten passphrase). Wipes stored tokens.
$("#reset-link").addEventListener("click", async (e) => {
  e.preventDefault();
  if (!confirm("Reset the vault? This deletes all stored provider tokens on this machine. You'll set a new passphrase on next unlock."))
    return;
  await call("reset_vault");
  $("#pass").value = "";
  toast("vault reset — set a new passphrase to continue");
});

// ---- Tab switching ----
$$(".tab").forEach((btn) => {
  btn.addEventListener("click", () => {
    $$(".tab").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    $$(".view").forEach((v) => v.classList.add("hidden"));
    $(`#tab-${btn.dataset.tab}`).classList.remove("hidden");
    if (btn.dataset.tab === "usage") refreshUsage();
    if (btn.dataset.tab === "providers") refreshProviders();
  });
});

// ---- Config (mode + privacy) ----
async function loadConfig() {
  const cfg = await call("get_config");
  $("#worker-id").textContent = cfg.worker_id;
  const m = $(`input[name=mode][value=${cfg.execution_mode}]`);
  if (m) m.checked = true;
  const ext = cfg.external_allowed_levels || [];
  $$(".ext").forEach((c) => (c.checked = ext.includes(c.value)));
  $("#pref").value = cfg.routing_preference;
  // Show the URL a run will actually use (resolved from config / env / bake / default), and
  // prefill the input with the saved config value if any.
  $("#coord-effective").textContent = cfg.resolved_coordinator_url || "(default)";
  if (cfg.coordinator_url && !$("#r-url").value) $("#r-url").value = cfg.coordinator_url;
}

$("#save-url").addEventListener("click", async () => {
  const resolved = await call("set_coordinator_url", { url: $("#r-url").value.trim() });
  $("#coord-effective").textContent = resolved || "(default)";
  toast("coordinator set: " + (resolved || "default"));
});

// ---- Run (start / stop / live status) ----
$("#start-worker").addEventListener("click", async () => {
  // Start uses the saved config URL (resolved) — no per-start override, so what you see in the
  // "connect to" box is exactly what it uses. Save a URL first to change it.
  await call("start_worker", { coordinator_url: null });
  toast("worker starting…");
  pollStatus();
});

$("#stop-worker").addEventListener("click", async () => {
  await call("stop_worker");
  toast("worker stopped");
  pollStatus();
});

function fmtTime(unix) {
  return unix > 0 ? new Date(unix * 1000).toLocaleTimeString() : "—";
}

async function pollStatus() {
  let s;
  try {
    s = await invoke("worker_status"); // silent: polled frequently, don't toast errors
  } catch {
    return;
  }
  const state = s.running ? (s.connected ? "connected" : "connecting…") : "stopped";
  const cls = s.running ? (s.connected ? "on" : "warn") : "off";
  $("#run-state").textContent = state;
  if (s.coordinator_url) $("#run-coord").textContent = s.coordinator_url;
  if (s.worker_id) $("#run-wid").textContent = s.worker_id;
  $("#run-connected").textContent = s.connected ? "yes" : "no";
  $("#run-jobs").textContent = s.jobs_processed;
  $("#run-started").textContent = s.running ? fmtTime(s.started_unix) : "—";
  $("#run-error").textContent = s.last_error || "—";
  $("#run-error").className = "mono" + (s.last_error ? " status-bad" : "");
  for (const dot of [$("#run-dot"), $("#rail-dot")]) dot.className = `dot ${cls}`;
  $("#rail-label").textContent = state;
  $("#rail-label").className = s.running ? (s.connected ? "status-ok" : "muted") : "muted";
}

function startStatusPolling() {
  if (startStatusPolling._t) return;
  pollStatus();
  startStatusPolling._t = setInterval(pollStatus, 1500);
}

$("#save-mode").addEventListener("click", async () => {
  const mode = $("input[name=mode]:checked")?.value;
  if (!mode) return toast("pick a mode", true);
  await call("set_mode", { mode });
  toast(`mode set to ${mode}`);
});

$("#save-privacy").addEventListener("click", async () => {
  await call("set_privacy", {
    external_allowed_levels: $$(".ext").filter((c) => c.checked).map((c) => c.value),
    routing_preference: $("#pref").value,
  });
  toast("routing saved");
});

// ---- Providers ----
async function refreshProviders() {
  const rows = await call("list_providers");
  const tbody = $("#provider-rows");
  tbody.innerHTML = "";
  for (const p of rows) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${p.name}</td>
      <td class="fp">${p.fingerprint}</td>
      <td data-status>—</td>
      <td style="text-align:right">
        <button data-test>Test</button>
        <button class="danger" data-remove>Remove</button>
      </td>`;
    tr.querySelector("[data-test]").addEventListener("click", async () => {
      const cell = tr.querySelector("[data-status]");
      cell.textContent = "testing…";
      const res = await call("test_provider", { name: p.name, base_url: null });
      cell.textContent = res.ok ? "OK" : res.error || "rejected";
      cell.className = res.ok ? "status-ok" : "status-bad";
    });
    tr.querySelector("[data-remove]").addEventListener("click", async () => {
      await call("remove_provider", { name: p.name });
      toast(`removed ${p.name}`);
      refreshProviders();
    });
    tbody.appendChild(tr);
  }
}

async function loginProvider(name, btn) {
  const prev = btn.textContent;
  btn.disabled = true;
  btn.textContent = "opening browser…";
  try {
    const view = await call("login_provider", { name });
    toast(`signed in: ${view.name} (${view.fingerprint})`);
    refreshProviders();
  } finally {
    btn.disabled = false;
    btn.textContent = prev;
  }
}
$("#login-openai").addEventListener("click", (e) => loginProvider("openai", e.currentTarget));
$("#login-gemini").addEventListener("click", (e) => loginProvider("gemini", e.currentTarget));

$("#add-provider").addEventListener("click", async () => {
  const name = $("#p-name").value.trim();
  const baseUrl = $("#p-base").value.trim() || null;
  const token = $("#p-token").value;
  if (!name || !token) return toast("name and token required", true);
  const view = await call("add_provider", { name, base_url: baseUrl, token });
  $("#p-token").value = "";
  $("#p-name").value = "";
  $("#p-base").value = "";
  toast(`stored ${view.name} (${view.fingerprint})`);
  refreshProviders();
});

// ---- Usage ----
async function refreshUsage() {
  const period = $("#u-period").value.trim() || null;
  const rows = await call("usage", { period });
  const tbody = $("#usage-rows");
  tbody.innerHTML = "";
  for (const r of rows) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${r.provider}</td><td>${r.model}</td><td>${r.period}</td>
      <td>${r.requests}</td><td>${r.input_tokens}</td><td>${r.output_tokens}</td>
      <td class="status-ok">${r.successful_jobs}</td><td class="status-bad">${r.failed_jobs}</td>
      <td>${r.estimated_cost_usd.toFixed(4)}</td><td>${Math.round(r.average_latency_ms)}ms</td>`;
    tbody.appendChild(tr);
  }
  if (!rows.length) tbody.innerHTML = `<tr><td colspan="10" class="muted">No usage recorded.</td></tr>`;
}
$("#refresh-usage").addEventListener("click", refreshUsage);
