defmodule Coordinator.Web.TokenController do
  @moduledoc """
  Admin console for gateway API keys (`Coordinator.ApiTokens`). Server-rendered HTML (no JS
  build): list keys, mint a new one (the plaintext is shown exactly once, carried across the
  post-redirect via a one-shot session entry), and revoke.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Coordinator.ApiTokens

  def index(conn, _params) do
    # One-shot reveal: a freshly minted key is stashed in the session by create/2, shown once
    # here, then removed so a refresh won't display it again.
    new_token = get_session(conn, :new_token)
    conn = delete_session(conn, :new_token)

    html(conn, page(conn, ApiTokens.list(), new_token))
  end

  def create(conn, params) do
    label = params["label"] |> to_string() |> String.trim()

    conn =
      case label do
        "" ->
          conn

        label ->
          case ApiTokens.create(label, conn.assigns[:current_admin]) do
            {:ok, plaintext, _record} -> put_session(conn, :new_token, plaintext)
            {:error, _} -> conn
          end
      end

    redirect(conn, to: "/admin")
  end

  def revoke(conn, %{"id" => id}) do
    ApiTokens.revoke(id)
    redirect(conn, to: "/admin")
  end

  # ---- rendering (plain HTML; user input is escaped) ----------------------------------------

  defp page(conn, tokens, new_token) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>hydra admin — API keys</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body{font-family:system-ui,sans-serif;max-width:820px;margin:2rem auto;padding:0 1rem;color:#111}
      h1{font-size:1.4rem} h2{font-size:1.05rem;margin-top:2rem}
      table{border-collapse:collapse;width:100%;font-size:.9rem}
      th,td{text-align:left;padding:.45rem .5rem;border-bottom:1px solid #e5e5e5}
      code{background:#f4f4f4;padding:.15rem .35rem;border-radius:4px}
      .reveal{background:#eef9f0;border:1px solid #bfe3c7;padding:1rem;border-radius:8px;margin:1rem 0}
      .reveal code{background:#dff3e3;font-size:1rem;user-select:all}
      .muted{color:#888} .revoked{color:#b00;text-decoration:line-through}
      form.inline{display:inline} input[type=text]{padding:.4rem;min-width:16rem}
      button{padding:.4rem .7rem;cursor:pointer} nav a{margin-right:1rem}
    </style></head><body>
    <h1>hydra coordinator — API keys</h1>
    <nav><a href="/admin/oban">Oban dashboard →</a><a href="/auth/logout">Log out (#{esc(conn.assigns[:current_admin])})</a></nav>
    #{reveal(new_token)}
    <h2>Issue a key</h2>
    <form method="post" action="/admin/tokens">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      <input type="text" name="label" placeholder="label (e.g. laptop-cli, staging)" required>
      <button type="submit">Create</button>
    </form>
    <h2>Existing keys</h2>
    <table><thead><tr><th>Label</th><th>Created</th><th>Last used</th><th>Status</th><th></th></tr></thead>
    <tbody>#{rows(tokens, csrf)}</tbody></table>
    </body></html>
    """
  end

  defp reveal(nil), do: ""

  defp reveal(token) do
    """
    <div class="reveal"><strong>New key — copy it now, it will not be shown again:</strong><br>
    <code>#{esc(token)}</code></div>
    """
  end

  defp rows([], _csrf),
    do: ~s(<tr><td colspan="5" class="muted">No keys yet.</td></tr>)

  defp rows(tokens, csrf) do
    Enum.map_join(tokens, "", fn t ->
      status =
        if t.revoked_at,
          do: ~s(<span class="revoked">revoked</span>),
          else: "active"

      action =
        if t.revoked_at do
          ""
        else
          """
          <form class="inline" method="post" action="/admin/tokens/#{esc(t.id)}/revoke"
                onsubmit="return confirm('Revoke this key?')">
            <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
            <button type="submit">Revoke</button>
          </form>
          """
        end

      """
      <tr>
        <td>#{esc(t.label)}<br><span class="muted">by #{esc(t.created_by || "—")}</span></td>
        <td>#{fmt(t.inserted_at)}</td>
        <td>#{fmt(t.last_used_at)}</td>
        <td>#{status}</td>
        <td>#{action}</td>
      </tr>
      """
    end)
  end

  defp esc(nil), do: ""
  defp esc(v), do: v |> to_string() |> Plug.HTML.html_escape()

  defp fmt(nil), do: ~s(<span class="muted">never</span>)
  defp fmt(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M")
  defp fmt(other), do: esc(other)
end
