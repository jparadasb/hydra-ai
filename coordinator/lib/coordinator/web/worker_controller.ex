defmodule Coordinator.Web.WorkerController do
  @moduledoc """
  Admin console for enrolled workers (`worker_keys`): grant the job privacy levels each
  worker may accept (`Coordinator.WorkerPolicies`) and revoke/restore its device key.
  Uses the shared admin shell (`Coordinator.Web.AdminLayout`) for theme, nav, and flashes.
  """
  use Phoenix.Controller, formats: [:html]

  import Coordinator.Web.AdminLayout, only: [esc: 1, fmt_dt: 1]

  alias Coordinator.{DeviceAuth, WorkerKey, WorkerPolicies, WorkerRegistry}
  alias Coordinator.Web.AdminLayout

  def index(conn, _params) do
    connected = WorkerRegistry.list() |> Map.new(&{&1.worker_id, &1})
    html(conn, page(conn, WorkerPolicies.list(), connected))
  end

  def policy(conn, %{"id" => worker_id} = params) do
    levels =
      params
      |> Map.get("levels", [])
      |> List.wrap()
      |> Enum.filter(&(&1 in WorkerKey.privacy_levels()))

    WorkerPolicies.set_accepted_levels(worker_id, levels)

    summary = if levels == [], do: "none", else: Enum.join(levels, ", ")

    conn
    |> put_flash(:info, "Privacy levels for #{worker_id} set to: #{summary}.")
    |> redirect(to: "/admin/workers")
  end

  def revoke(conn, %{"id" => worker_id}) do
    DeviceAuth.revoke(worker_id)

    conn
    |> put_flash(:info, "Worker key for #{worker_id} revoked — it will be rejected on reconnect.")
    |> redirect(to: "/admin/workers")
  end

  def restore(conn, %{"id" => worker_id}) do
    DeviceAuth.restore(worker_id)

    conn
    |> put_flash(:info, "Worker key for #{worker_id} restored.")
    |> redirect(to: "/admin/workers")
  end

  # ---- rendering (plain HTML; user input is escaped) ----------------------------------------

  defp page(conn, keys, connected) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    body = """
    <h1>Workers</h1>
    <p class="lead">Privacy acceptance is granted here, per worker. Workers start public-only;
    whatever a worker declares for itself is ignored. Changes apply to connected workers
    immediately.</p>

    <div class="table-wrap">
      <table>
        <thead><tr><th>Worker</th><th>Seen</th><th>Accepted job levels</th><th>Key</th></tr></thead>
        <tbody>#{rows(keys, connected, csrf)}</tbody>
      </table>
    </div>
    """

    AdminLayout.page(conn, title: "Workers", active: :workers, body: body)
  end

  defp rows([], _connected, _csrf) do
    ~s(<tr><td colspan="4" class="muted">No enrolled workers yet — they appear here after their first connection.</td></tr>)
  end

  defp rows(keys, connected, csrf) do
    Enum.map_join(keys, "", fn key ->
      live = Map.get(connected, key.worker_id)

      presence =
        if live do
          ~s(<span class="badge badge-ok"><span class="dot"></span>connected</span> <span class="muted">#{length(live.models)} models</span>)
        else
          ~s(<span class="badge badge-off">offline</span>)
        end

      """
      <tr>
        <td><code>#{esc(key.worker_id)}</code><br>#{presence}</td>
        <td><span class="muted">first #{fmt_dt(key.first_seen_at)}<br>last #{fmt_dt(key.last_seen_at)}</span></td>
        <td>#{policy_form(key, csrf)}</td>
        <td>#{key_status(key, csrf)}</td>
      </tr>
      """
    end)
  end

  defp policy_form(key, csrf) do
    chips =
      Enum.map_join(WorkerKey.privacy_levels(), "", fn level ->
        checked = if level in (key.accepted_job_levels || []), do: " checked", else: ""

        """
        <label class="chip"><input type="checkbox" name="levels[]" value="#{level}"#{checked}><span>#{level}</span></label>
        """
      end)

    """
    <form method="post" action="/admin/workers/#{esc(key.worker_id)}/policy">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      <div class="chips">#{chips}<button type="submit" class="btn-sm">Save</button></div>
    </form>
    """
  end

  defp key_status(%WorkerKey{status: "revoked"} = key, csrf) do
    """
    <span class="badge badge-danger">revoked</span>
    <form class="inline" method="post" action="/admin/workers/#{esc(key.worker_id)}/restore">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      <button type="submit" class="btn-sm">Restore</button>
    </form>
    """
  end

  defp key_status(key, csrf) do
    """
    <span class="badge badge-ok">trusted</span>
    <form class="inline" method="post" action="/admin/workers/#{esc(key.worker_id)}/revoke"
          onsubmit="return confirm('Revoke this worker key? It will be rejected on reconnect.')">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      <button type="submit" class="btn-danger btn-sm">Revoke</button>
    </form>
    """
  end
end
