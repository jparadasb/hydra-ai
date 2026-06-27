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
});
$("#pass").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("#unlock-btn").click();
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
  $$(".lvl").forEach((c) => (c.checked = cfg.privacy.accepted_job_levels.includes(c.value)));
  $("#allow-private").checked = cfg.privacy.allow_private_jobs;
  $("#allow-sensitive").checked = cfg.privacy.allow_sensitive_jobs;
  $("#pref").value = cfg.routing_preference;
}

$("#save-mode").addEventListener("click", async () => {
  const mode = $("input[name=mode]:checked")?.value;
  if (!mode) return toast("pick a mode", true);
  await call("set_mode", { mode });
  toast(`mode set to ${mode}`);
});

$("#save-privacy").addEventListener("click", async () => {
  await call("set_privacy", {
    accepted_levels: $$(".lvl").filter((c) => c.checked).map((c) => c.value),
    allow_private: $("#allow-private").checked,
    allow_sensitive: $("#allow-sensitive").checked,
    routing_preference: $("#pref").value,
  });
  toast("privacy saved");
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
