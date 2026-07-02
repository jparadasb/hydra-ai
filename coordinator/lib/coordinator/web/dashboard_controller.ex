defmodule Coordinator.Web.DashboardController do
  @moduledoc """
  Admin dashboard: connected workers vs pending/processed jobs, with charts.

  * `GET /admin/dashboard` — static HTML shell (Tailwind + Chart.js via CDN, no asset build).
  * `GET /admin/stats`     — JSON snapshot (`Coordinator.Stats`) the page polls every 5s.

  Both sit behind the `/admin` auth pipeline (GitHub OAuth in prod, open on loopback dev).
  The page contains no server-interpolated user data; everything dynamic comes from the JSON
  endpoint and is written with `textContent`, so there is nothing to escape.
  """
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  def stats(conn, _params) do
    json(conn, Coordinator.Stats.snapshot())
  end

  def index(conn, _params) do
    html(conn, page())
  end

  defp page do
    """
    <!DOCTYPE html>
    <html class="h-full">
    <head>
      <meta charset="utf-8">
      <title>hydra admin — dashboard</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <script src="https://cdn.tailwindcss.com"></script>
      <script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
    </head>
    <body class="h-full bg-slate-950 text-slate-100 font-sans">
      <div class="max-w-6xl mx-auto px-4 py-8">
        <header class="flex items-baseline justify-between mb-8">
          <h1 class="text-xl font-semibold tracking-tight">hydra coordinator</h1>
          <nav class="space-x-4 text-sm text-slate-400">
            <a class="hover:text-white" href="/admin">API keys</a>
            <a class="hover:text-white" href="/admin/oban">Oban</a>
            <a class="hover:text-white" href="/auth/logout">Log out</a>
          </nav>
        </header>

        <!-- stat cards -->
        <div class="grid grid-cols-2 md:grid-cols-6 gap-3 mb-8">
          <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
            <div class="text-xs uppercase tracking-wide text-slate-400">Workers</div>
            <div id="stat-workers" class="text-3xl font-semibold mt-1">–</div>
          </div>
          <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
            <div class="text-xs uppercase tracking-wide text-slate-400">Inflight</div>
            <div id="stat-inflight" class="text-3xl font-semibold mt-1">–</div>
          </div>
          <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
            <div class="text-xs uppercase tracking-wide text-amber-400">Pending</div>
            <div id="stat-pending" class="text-3xl font-semibold mt-1">–</div>
          </div>
          <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
            <div class="text-xs uppercase tracking-wide text-sky-400">Leased</div>
            <div id="stat-leased" class="text-3xl font-semibold mt-1">–</div>
          </div>
          <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
            <div class="text-xs uppercase tracking-wide text-emerald-400">Done</div>
            <div id="stat-done" class="text-3xl font-semibold mt-1">–</div>
          </div>
          <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
            <div class="text-xs uppercase tracking-wide text-rose-400">Failed</div>
            <div id="stat-failed" class="text-3xl font-semibold mt-1">–</div>
          </div>
        </div>

        <!-- charts -->
        <div class="grid md:grid-cols-3 gap-3 mb-8">
          <div class="md:col-span-2 rounded-xl bg-slate-900 border border-slate-800 p-4">
            <h2 class="text-sm font-medium text-slate-300 mb-3">Processed jobs — last 24h</h2>
            <canvas id="chart-throughput" height="110"></canvas>
          </div>
          <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
            <h2 class="text-sm font-medium text-slate-300 mb-3">Job status</h2>
            <canvas id="chart-status" height="110"></canvas>
          </div>
        </div>

        <!-- workers table -->
        <div class="rounded-xl bg-slate-900 border border-slate-800 p-4">
          <h2 class="text-sm font-medium text-slate-300 mb-3">Connected workers</h2>
          <table class="w-full text-sm">
            <thead class="text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th class="py-2 pr-4">Worker</th>
                <th class="py-2 pr-4">Mode</th>
                <th class="py-2 pr-4">Models</th>
                <th class="py-2 pr-4">Capabilities</th>
                <th class="py-2 pr-4 text-right">Inflight</th>
                <th class="py-2 pr-4 text-right">Avg latency</th>
                <th class="py-2">Status</th>
              </tr>
            </thead>
            <tbody id="workers-body">
              <tr><td colspan="7" class="py-4 text-slate-500">Loading…</td></tr>
            </tbody>
          </table>
        </div>

        <p class="mt-4 text-xs text-slate-600">
          Auto-refreshes every 5s · <span id="updated-at"></span>
        </p>
      </div>

      <script>
        const fmtHour = iso => new Date(iso).toLocaleTimeString([], {hour: '2-digit'});

        const throughputChart = new Chart(document.getElementById('chart-throughput'), {
          type: 'bar',
          data: { labels: [], datasets: [
            { label: 'done',   data: [], backgroundColor: 'rgba(52,211,153,0.8)', stack: 's' },
            { label: 'failed', data: [], backgroundColor: 'rgba(251,113,133,0.8)', stack: 's' }
          ]},
          options: {
            responsive: true,
            scales: {
              x: { stacked: true, ticks: { color: '#64748b' }, grid: { display: false } },
              y: { stacked: true, beginAtZero: true, ticks: { color: '#64748b', precision: 0 }, grid: { color: '#1e293b' } }
            },
            plugins: { legend: { labels: { color: '#94a3b8' } } }
          }
        });

        const statusChart = new Chart(document.getElementById('chart-status'), {
          type: 'doughnut',
          data: { labels: ['pending', 'leased', 'done', 'failed'], datasets: [{
            data: [0, 0, 0, 0],
            backgroundColor: ['rgba(251,191,36,0.85)', 'rgba(56,189,248,0.85)', 'rgba(52,211,153,0.85)', 'rgba(251,113,133,0.85)'],
            borderColor: '#0f172a'
          }]},
          options: { responsive: true, plugins: { legend: { position: 'bottom', labels: { color: '#94a3b8' } } } }
        });

        function cell(text, cls) {
          const td = document.createElement('td');
          td.className = 'py-2 pr-4 ' + (cls || '');
          td.textContent = text;
          return td;
        }

        async function refresh() {
          let s;
          try {
            const resp = await fetch('/admin/stats', { headers: { accept: 'application/json' } });
            if (!resp.ok) return;
            s = await resp.json();
          } catch (_) { return; }

          const workers = s.workers || [];
          const jobs = s.jobs || {};
          document.getElementById('stat-workers').textContent = workers.length;
          document.getElementById('stat-inflight').textContent = workers.reduce((n, w) => n + (w.inflight || 0), 0);
          for (const k of ['pending', 'leased', 'done', 'failed'])
            document.getElementById('stat-' + k).textContent = jobs[k] ?? 0;

          const tp = s.throughput || [];
          throughputChart.data.labels = tp.map(b => fmtHour(b.hour));
          throughputChart.data.datasets[0].data = tp.map(b => b.done);
          throughputChart.data.datasets[1].data = tp.map(b => b.failed);
          throughputChart.update('none');

          statusChart.data.datasets[0].data = ['pending', 'leased', 'done', 'failed'].map(k => jobs[k] ?? 0);
          statusChart.update('none');

          const body = document.getElementById('workers-body');
          body.replaceChildren();
          if (workers.length === 0) {
            const tr = document.createElement('tr');
            tr.appendChild(cell('No workers connected.', 'text-slate-500'));
            tr.firstChild.colSpan = 7;
            body.appendChild(tr);
          }
          for (const w of workers) {
            const tr = document.createElement('tr');
            tr.className = 'border-t border-slate-800';
            tr.appendChild(cell(w.worker_id, 'font-mono text-xs'));
            tr.appendChild(cell(w.execution_mode + (w.provider ? ' · ' + w.provider : '')));
            tr.appendChild(cell(String(w.models)));
            tr.appendChild(cell((w.capabilities || []).join(', '), 'text-slate-400 text-xs'));
            tr.appendChild(cell(String(w.inflight), 'text-right'));
            tr.appendChild(cell(Math.round(w.avg_latency_ms) + ' ms', 'text-right text-slate-400'));
            const status = cell(w.available ? 'available' : 'busy',
              w.available ? 'text-emerald-400' : 'text-amber-400');
            status.classList.remove('pr-4');
            tr.appendChild(status);
            body.appendChild(tr);
          }

          document.getElementById('updated-at').textContent =
            'updated ' + new Date().toLocaleTimeString();
        }

        refresh();
        setInterval(refresh, 5000);
      </script>
    </body>
    </html>
    """
  end
end
