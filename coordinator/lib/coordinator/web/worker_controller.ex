defmodule Coordinator.Web.WorkerController do
  @moduledoc """
  Admin console for enrolled workers (`worker_keys`): grant the job privacy levels each
  worker may accept (`Coordinator.WorkerPolicies`) and revoke/restore its device key.
  Server-rendered HTML in the same style as `Coordinator.Web.TokenController`.
  """
  use Phoenix.Controller, formats: [:html]

  alias Coordinator.{DeviceAuth, WorkerKey, WorkerPolicies, WorkerRegistry}

  def index(conn, _params) do
    connected = WorkerRegistry.list() |> Map.new(&{&1.worker_id, &1})
    html(conn, page(WorkerPolicies.list(), connected))
  end

  def policy(conn, %{"id" => worker_id} = params) do
    levels =
      params
      |> Map.get("levels", [])
      |> List.wrap()
      |> Enum.filter(&(&1 in WorkerKey.privacy_levels()))

    WorkerPolicies.set_accepted_levels(worker_id, levels)
    redirect(conn, to: "/admin/workers")
  end

  def revoke(conn, %{"id" => worker_id}) do
    DeviceAuth.revoke(worker_id)
    redirect(conn, to: "/admin/workers")
  end

  def restore(conn, %{"id" => worker_id}) do
    DeviceAuth.restore(worker_id)
    redirect(conn, to: "/admin/workers")
  end

  # ---- rendering (plain HTML; user input is escaped) ----------------------------------------

  defp page(keys, connected) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>hydra admin — workers</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body{font-family:system-ui,sans-serif;max-width:980px;margin:2rem auto;padding:0 1rem;color:#111}
      h1{font-size:1.4rem}
      table{border-collapse:collapse;width:100%;font-size:.9rem}
      th,td{text-align:left;padding:.45rem .5rem;border-bottom:1px solid #e5e5e5;vertical-align:top}
      code{background:#f4f4f4;padding:.15rem .35rem;border-radius:4px}
      .muted{color:#888} .revoked{color:#b00} .online{color:#0a7d33}
      label{margin-right:.8rem;white-space:nowrap}
      form.inline{display:inline}
      button{padding:.3rem .6rem;cursor:pointer} nav a{margin-right:1rem}
    </style></head><body>
    <h1>hydra coordinator — workers</h1>
    <nav><a href="/admin">API keys →</a><a href="/admin/dashboard">Dashboard →</a><a href="/admin/oban">Oban →</a></nav>
    <p class="muted">Privacy acceptance is granted here, per worker. Workers start public-only;
    whatever a worker declares for itself is ignored. Changes apply to connected workers
    immediately.</p>
    <table><thead><tr><th>Worker</th><th>Seen</th><th>Accepted job levels</th><th>Key</th></tr></thead>
    <tbody>#{rows(keys, connected, csrf)}</tbody></table>
    </body></html>
    """
  end

  defp rows([], _connected, _csrf),
    do: ~s(<tr><td colspan="4" class="muted">No enrolled workers yet.</td></tr>)

  defp rows(keys, connected, csrf) do
    Enum.map_join(keys, "", fn key ->
      live = Map.get(connected, key.worker_id)

      presence =
        if live,
          do: ~s(<span class="online">connected</span> · #{length(live.models)} models),
          else: ~s(<span class="muted">offline</span>)

      """
      <tr>
        <td><code>#{esc(key.worker_id)}</code><br><span class="muted">#{presence}</span></td>
        <td><span class="muted">first #{fmt(key.first_seen_at)}<br>last #{fmt(key.last_seen_at)}</span></td>
        <td>#{policy_form(key, csrf)}</td>
        <td>#{key_status(key, csrf)}</td>
      </tr>
      """
    end)
  end

  defp policy_form(key, csrf) do
    boxes =
      Enum.map_join(WorkerKey.privacy_levels(), "", fn level ->
        checked = if level in (key.accepted_job_levels || []), do: " checked", else: ""

        ~s(<label><input type="checkbox" name="levels[]" value="#{level}"#{checked}> #{level}</label>)
      end)

    """
    <form class="inline" method="post" action="/admin/workers/#{esc(key.worker_id)}/policy">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      #{boxes}<button type="submit">Save</button>
    </form>
    """
  end

  defp key_status(%WorkerKey{status: "revoked"} = key, csrf) do
    """
    <span class="revoked">revoked</span>
    <form class="inline" method="post" action="/admin/workers/#{esc(key.worker_id)}/restore">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      <button type="submit">Restore</button>
    </form>
    """
  end

  defp key_status(key, csrf) do
    """
    trusted
    <form class="inline" method="post" action="/admin/workers/#{esc(key.worker_id)}/revoke"
          onsubmit="return confirm('Revoke this worker key? It will be rejected on reconnect.')">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      <button type="submit">Revoke</button>
    </form>
    """
  end

  defp esc(nil), do: ""
  defp esc(v), do: v |> to_string() |> Plug.HTML.html_escape()

  defp fmt(nil), do: "never"
  defp fmt(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M")
  defp fmt(other), do: esc(other)
end
