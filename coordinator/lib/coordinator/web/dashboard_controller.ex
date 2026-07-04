defmodule Coordinator.Web.DashboardController do
  @moduledoc """
  Admin dashboard: connected workers vs pending/processed jobs, with charts.

  * `GET /admin/dashboard` — HTML shell from `Coordinator.Web.AdminLayout` (inline CSS, no
    asset build; only Chart.js comes from a CDN and the page degrades gracefully without it).
  * `GET /admin/stats`     — JSON snapshot (`Coordinator.Stats`) the page polls every 5s.

  Both sit behind the `/admin` auth pipeline (GitHub OAuth in prod, open on loopback dev).
  The page contains no server-interpolated user data; everything dynamic comes from the JSON
  endpoint and is written with `textContent`, so there is nothing to escape.
  """
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  alias Coordinator.Web.AdminLayout

  def stats(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(Coordinator.Stats.snapshot())
  end

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> html(page(conn))
  end

  defp page(conn) do
    AdminLayout.page(conn,
      title: "dashboard",
      active: :dashboard,
      head_extra: ~s(<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>),
      body: body()
    )
  end

  defp body do
    """
    <h1>Dashboard</h1>
    <p class="lead">Connected workers and job flow. Auto-refreshes every 5 seconds.</p>

    <!-- stat cards -->
    <div class="stats-grid">
      <div class="stat"><div class="stat-label">Workers</div><div id="stat-workers" class="stat-value">–</div></div>
      <div class="stat"><div class="stat-label">Inflight</div><div id="stat-inflight" class="stat-value">–</div></div>
      <div class="stat"><div class="stat-label warn">Pending</div><div id="stat-pending" class="stat-value">–</div></div>
      <div class="stat"><div class="stat-label sky">Leased</div><div id="stat-leased" class="stat-value">–</div></div>
      <div class="stat"><div class="stat-label ok">Done</div><div id="stat-done" class="stat-value">–</div></div>
      <div class="stat"><div class="stat-label bad">Failed</div><div id="stat-failed" class="stat-value">–</div></div>
    </div>

    <!-- charts -->
    <div class="charts">
      <div class="panel">
        <h2 style="margin-top:0">Processed jobs — last 24h</h2>
        <canvas id="chart-throughput" height="110"></canvas>
      </div>
      <div class="panel">
        <h2 style="margin-top:0">Job status</h2>
        <canvas id="chart-status" height="110"></canvas>
      </div>
    </div>

    <!-- workers table -->
    <h2>Connected workers</h2>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Worker</th><th>Mode</th><th>Models</th><th>Capabilities</th>
            <th>Accepted</th><th class="num">Inflight</th><th class="num">Avg latency</th><th>Status</th>
          </tr>
        </thead>
        <tbody id="workers-body">
          <tr><td colspan="8" class="muted">Loading…</td></tr>
        </tbody>
      </table>
    </div>

    <p class="footnote">Auto-refreshes every 5s · <span id="updated-at"></span></p>

    <script>
      // Resilient by construction: the stat cards and workers table always render, even if
      // the Chart.js CDN is blocked (adblock/privacy shields) — charts are created lazily and
      // guarded. Any fetch/render problem is surfaced in the footer instead of dying silently.
      const C = {
        accent: '#4ade80', warn: '#fbbf24', sky: '#38bdf8', danger: '#f87171',
        muted: '#7d8aa0', grid: '#232c3a', panel: '#151a21'
      };
      const fmtHour = iso => new Date(iso).toLocaleTimeString([], {hour: '2-digit'});
      const note = msg => { document.getElementById('updated-at').textContent = msg; };
      let throughputChart = null, statusChart = null;

      function ensureCharts() {
        if (throughputChart || typeof Chart === 'undefined') return;
        throughputChart = new Chart(document.getElementById('chart-throughput'), {
          type: 'bar',
          data: { labels: [], datasets: [
            { label: 'done',   data: [], backgroundColor: C.accent, stack: 's' },
            { label: 'failed', data: [], backgroundColor: C.danger, stack: 's' }
          ]},
          options: {
            responsive: true,
            scales: {
              x: { stacked: true, ticks: { color: C.muted }, grid: { display: false } },
              y: { stacked: true, beginAtZero: true, ticks: { color: C.muted, precision: 0 }, grid: { color: C.grid } }
            },
            plugins: { legend: { labels: { color: C.muted } } }
          }
        });
        statusChart = new Chart(document.getElementById('chart-status'), {
          type: 'doughnut',
          data: { labels: ['pending', 'leased', 'done', 'failed'], datasets: [{
            data: [0, 0, 0, 0],
            backgroundColor: [C.warn, C.sky, C.accent, C.danger],
            borderColor: C.panel
          }]},
          options: { responsive: true, plugins: { legend: { position: 'bottom', labels: { color: C.muted } } } }
        });
      }

      function cell(text, cls) {
        const td = document.createElement('td');
        if (cls) td.className = cls;
        td.textContent = text;
        return td;
      }

      function badge(text, ok) {
        const td = document.createElement('td');
        const span = document.createElement('span');
        span.className = ok ? 'badge badge-ok' : 'badge badge-warn';
        span.textContent = text;
        td.appendChild(span);
        return td;
      }

      function renderCardsAndTable(s) {
        const workers = s.workers || [];
        const jobs = s.jobs || {};
        document.getElementById('stat-workers').textContent = workers.length;
        document.getElementById('stat-inflight').textContent = workers.reduce((n, w) => n + (w.inflight || 0), 0);
        for (const k of ['pending', 'leased', 'done', 'failed'])
          document.getElementById('stat-' + k).textContent = jobs[k] ?? 0;

        const body = document.getElementById('workers-body');
        body.replaceChildren();
        if (workers.length === 0) {
          const tr = document.createElement('tr');
          const td = cell('No workers connected.', 'muted');
          td.colSpan = 8;
          tr.appendChild(td);
          body.appendChild(tr);
        }
        for (const w of workers) {
          const tr = document.createElement('tr');
          tr.appendChild(cell(w.worker_id, 'mono'));
          tr.appendChild(cell(w.execution_mode + (w.provider ? ' · ' + w.provider : '')));
          tr.appendChild(cell(String(w.models)));
          tr.appendChild(cell((w.capabilities || []).join(', '), 'muted'));
          tr.appendChild(cell((w.accepted_job_levels || []).join(', '), 'muted'));
          tr.appendChild(cell(String(w.inflight), 'num'));
          tr.appendChild(cell(Math.round(w.avg_latency_ms) + ' ms', 'num muted'));
          tr.appendChild(badge(w.available ? 'available' : 'busy', w.available));
          body.appendChild(tr);
        }
      }

      function renderCharts(s) {
        ensureCharts();
        if (!throughputChart) return;
        const jobs = s.jobs || {};
        const tp = s.throughput || [];
        throughputChart.data.labels = tp.map(b => fmtHour(b.hour));
        throughputChart.data.datasets[0].data = tp.map(b => b.done);
        throughputChart.data.datasets[1].data = tp.map(b => b.failed);
        throughputChart.update('none');
        statusChart.data.datasets[0].data = ['pending', 'leased', 'done', 'failed'].map(k => jobs[k] ?? 0);
        statusChart.update('none');
      }

      async function refresh() {
        let s;
        try {
          const resp = await fetch('/admin/stats', {
            headers: { accept: 'application/json' },
            credentials: 'same-origin',
            cache: 'no-store'
          });
          if (!resp.ok) { note('stats error HTTP ' + resp.status); return; }
          if (resp.redirected || (resp.headers.get('content-type') || '').indexOf('json') < 0) {
            note('session expired — reload the page to log in again');
            return;
          }
          s = await resp.json();
        } catch (e) { note('stats fetch failed: ' + e.message); return; }

        try { renderCardsAndTable(s); } catch (e) { note('render error: ' + e.message); return; }
        try { renderCharts(s); } catch (e) { note('chart error: ' + e.message); return; }
        note('updated ' + new Date().toLocaleTimeString() +
             (throughputChart ? '' : ' · charts unavailable (CDN blocked?)'));
      }

      refresh();
      setInterval(refresh, 5000);
    </script>
    """
  end
end
