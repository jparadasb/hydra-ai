defmodule Coordinator.Web.AdminLayout do
  @moduledoc """
  Shared shell for the server-rendered admin console pages (dashboard, API keys, workers).

  One place for the visual identity (same dark palette as the worker console and the landing
  page), the header/nav with active-tab state, and flash banners. Zero asset pipeline: all CSS
  is inlined, so the console renders fully even when CDNs are blocked. Pages pass pre-escaped
  HTML for `:body` (and optionally `:head_extra` for page-specific tags like Chart.js).
  """

  @nav [
    {:dashboard, "Dashboard", "/admin/dashboard"},
    {:tokens, "API keys", "/admin"},
    {:workers, "Workers", "/admin/workers"},
    {:oban, "Oban", "/admin/oban"}
  ]

  @doc """
  Render a full admin page. Options:

    * `:title`      — text after "hydra admin — " in the tab title (required)
    * `:active`     — nav tab key (`:dashboard | :tokens | :workers`), highlights the tab
    * `:body`       — page HTML (already escaped where it contains user data)
    * `:head_extra` — extra tags for `<head>` (optional)
  """
  def page(conn, opts) do
    title = Keyword.fetch!(opts, :title)
    active = Keyword.get(opts, :active)
    body = Keyword.fetch!(opts, :body)
    head_extra = Keyword.get(opts, :head_extra, "")

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>hydra admin — #{esc(title)}</title>
      <link rel="icon" href="data:image/svg+xml,#{favicon()}">
      <style>#{css()}</style>
      #{head_extra}
    </head>
    <body>
      <header class="topbar">
        <div class="shell topbar-inner">
          <span class="brand"><span class="brand-dot"></span>hydra <span class="muted">coordinator</span></span>
          <nav class="tabs">#{tabs(active)}</nav>
          <span class="whoami">#{whoami(conn)}</span>
        </div>
      </header>
      <main class="shell">
        #{flashes(conn)}
        #{body}
      </main>
    </body>
    </html>
    """
  end

  @doc "HTML-escape a value for interpolation into markup."
  def esc(nil), do: ""
  def esc(v), do: v |> to_string() |> Plug.HTML.html_escape()

  @doc ~s(Format a timestamp for tables; nil renders as a muted "never".)
  def fmt_dt(nil), do: ~s(<span class="muted">never</span>)

  def fmt_dt(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M")

  def fmt_dt(other), do: esc(other)

  # ---- pieces --------------------------------------------------------------------------------

  defp tabs(active) do
    Enum.map_join(@nav, "", fn {key, label, href} ->
      class = if key == active, do: "tab active", else: "tab"
      ~s(<a class="#{class}" href="#{href}">#{label}</a>)
    end)
  end

  defp whoami(conn) do
    admin = conn.assigns[:current_admin]
    ~s(<span class="muted">#{esc(admin)}</span> · <a href="/auth/logout">Log out</a>)
  end

  defp flashes(conn) do
    flash = Map.get(conn.assigns, :flash) || %{}

    for {kind, class} <- [info: "flash-info", error: "flash-error"],
        msg = Phoenix.Flash.get(flash, kind),
        is_binary(msg),
        into: "" do
      ~s(<div class="flash #{class}" role="status">#{esc(msg)}</div>)
    end
  end

  # Tiny inline favicon: signal-green dot on the console background.
  defp favicon do
    ~s(<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><rect width='16' height='16' rx='3' fill='%230e1116'/><circle cx='8' cy='8' r='4' fill='%234ade80'/></svg>)
    |> URI.encode()
  end

  # Same tokens as worker/ui/styles.css and the landing page.
  defp css do
    """
    :root{
      --bg:#0e1116;--panel:#151a21;--panel-2:#1b2230;--line:#232c3a;--text:#d6dee9;
      --muted:#7d8aa0;--accent:#4ade80;--accent-dim:#1f3a2c;--warn:#fbbf24;--danger:#f87171;
      --sky:#38bdf8;--radius:10px;
      --mono:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;
      --sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;
    }
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:14px/1.55 var(--sans);-webkit-font-smoothing:antialiased}
    a{color:var(--accent);text-decoration:none}
    a:hover{text-decoration:underline}
    :is(a,button,input,select):focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
    code,.mono{font-family:var(--mono)}
    code{background:var(--panel-2);border:1px solid var(--line);border-radius:5px;padding:.1rem .35rem;font-size:12px}
    .muted{color:var(--muted)}
    .shell{max-width:1100px;margin:0 auto;padding:0 20px}

    .topbar{border-bottom:1px solid var(--line);background:var(--panel);position:sticky;top:0;z-index:10}
    .topbar-inner{display:flex;align-items:center;gap:22px;height:54px}
    .brand{font:600 14px var(--mono);letter-spacing:.3px;display:inline-flex;align-items:center;gap:8px;white-space:nowrap}
    .brand-dot{width:8px;height:8px;border-radius:50%;background:var(--accent);box-shadow:0 0 10px var(--accent)}
    .tabs{display:flex;gap:4px;flex:1;overflow-x:auto}
    .tab{color:var(--muted);padding:6px 12px;border-radius:8px;font-size:13px;white-space:nowrap}
    .tab:hover{color:var(--text);text-decoration:none;background:var(--panel-2)}
    .tab.active{color:var(--accent);background:var(--accent-dim)}
    .whoami{font-size:12px;color:var(--muted);white-space:nowrap}
    .whoami a{color:var(--muted)}
    .whoami a:hover{color:var(--text)}

    main{padding:26px 20px 60px}
    h1{font:600 20px var(--mono);margin:0 0 4px}
    h2{font:600 14px var(--sans);color:var(--text);margin:28px 0 10px}
    .lead{color:var(--muted);margin:0 0 22px;max-width:70ch}

    .flash{border-radius:var(--radius);padding:10px 14px;margin:0 0 18px;font-size:13px}
    .flash-info{background:var(--accent-dim);border:1px solid var(--accent);color:var(--accent)}
    .flash-error{background:#3a1f22;border:1px solid var(--danger);color:var(--danger)}

    .panel{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:16px 18px}
    .table-wrap{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:var(--radius)}
    table{border-collapse:collapse;width:100%;font-size:13px}
    th{font:11px var(--mono);text-transform:uppercase;letter-spacing:.08em;color:var(--muted);text-align:left;padding:10px 14px;border-bottom:1px solid var(--line)}
    td{padding:11px 14px;border-bottom:1px solid var(--line);vertical-align:top}
    tr:last-child td{border-bottom:0}
    .num{text-align:right}

    .badge{display:inline-flex;align-items:center;gap:6px;font:11px var(--mono);border-radius:20px;padding:2px 9px;white-space:nowrap}
    .badge-ok{background:var(--accent-dim);color:var(--accent)}
    .badge-off{background:var(--panel-2);color:var(--muted)}
    .badge-warn{background:#3a2f14;color:var(--warn)}
    .badge-danger{background:#3a1f22;color:var(--danger)}
    .badge .dot{width:6px;height:6px;border-radius:50%;background:currentColor}

    button,.btn{font:600 13px var(--sans);color:var(--text);background:var(--panel-2);border:1px solid var(--line);border-radius:8px;padding:7px 14px;cursor:pointer}
    button:hover,.btn:hover{border-color:var(--muted)}
    .btn-primary{background:var(--accent-dim);border-color:var(--accent);color:var(--accent)}
    .btn-primary:hover{background:#244536}
    .btn-danger{background:transparent;border-color:transparent;color:var(--danger);padding:4px 8px}
    .btn-danger:hover{border-color:var(--danger)}
    .btn-sm{padding:4px 10px;font-size:12px}

    input[type=text]{font:inherit;color:var(--text);background:var(--panel-2);border:1px solid var(--line);border-radius:8px;padding:8px 12px;min-width:18rem}
    input[type=text]:focus{border-color:var(--accent);outline:none}
    input[type=text]::placeholder{color:var(--muted)}
    form.inline{display:inline}
    .form-row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}

    /* privacy-level chips: hidden checkbox, pill label */
    .chips{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
    .chip{position:relative;display:inline-flex}
    .chip input{position:absolute;opacity:0;inset:0;cursor:pointer}
    .chip span{font:12px var(--mono);color:var(--muted);background:var(--panel-2);border:1px solid var(--line);border-radius:20px;padding:3px 11px;cursor:pointer;user-select:none}
    .chip input:checked+span{color:var(--accent);background:var(--accent-dim);border-color:var(--accent)}
    .chip input:focus-visible+span{outline:2px solid var(--accent);outline-offset:2px}

    .reveal{background:var(--accent-dim);border:1px solid var(--accent);border-radius:var(--radius);padding:14px 16px;margin:0 0 22px}
    .reveal strong{color:var(--accent);font-size:13px}
    .reveal-key{display:flex;gap:10px;align-items:center;margin-top:8px;flex-wrap:wrap}
    .reveal-key code{font-size:13px;padding:.35rem .6rem;user-select:all;word-break:break-all;background:var(--bg);border-color:var(--accent)}

    .stats-grid{display:grid;grid-template-columns:repeat(6,1fr);gap:12px;margin-bottom:20px}
    .stat{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:14px 16px}
    .stat-label{font:11px var(--mono);text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
    .stat-label.ok{color:var(--accent)} .stat-label.warn{color:var(--warn)}
    .stat-label.sky{color:var(--sky)} .stat-label.bad{color:var(--danger)}
    .stat-value{font:600 26px var(--mono);margin-top:4px}
    .charts{display:grid;grid-template-columns:2fr 1fr;gap:12px;margin-bottom:20px}
    .footnote{margin-top:14px;font:12px var(--mono);color:var(--muted)}

    @media(max-width:900px){
      .stats-grid{grid-template-columns:repeat(3,1fr)}
      .charts{grid-template-columns:1fr}
      .whoami{display:none}
    }
    @media(max-width:560px){.stats-grid{grid-template-columns:repeat(2,1fr)}}
    """
  end
end
