defmodule Coordinator.Web.TokenController do
  @moduledoc """
  Admin console for gateway API keys (`Coordinator.ApiTokens`). Server-rendered HTML (no JS
  build): list keys, mint a new one (the plaintext is shown exactly once, carried across the
  post-redirect via a one-shot session entry), and revoke. Uses the shared admin shell
  (`Coordinator.Web.AdminLayout`) for the theme, nav, and flash feedback.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn
  import Coordinator.Web.AdminLayout, only: [esc: 1, fmt_dt: 1]

  alias Coordinator.ApiTokens
  alias Coordinator.Web.AdminLayout

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
          put_flash(conn, :error, "The key needs a label — try something like laptop-cli or staging.")

        label ->
          case ApiTokens.create(label, conn.assigns[:current_admin]) do
            {:ok, plaintext, _record} ->
              conn
              |> put_session(:new_token, plaintext)
              |> put_flash(:info, ~s(Key "#{label}" created.))

            {:error, _} ->
              put_flash(conn, :error, ~s(Could not create the key "#{label}".))
          end
      end

    redirect(conn, to: "/admin")
  end

  def revoke(conn, %{"id" => id}) do
    ApiTokens.revoke(id)

    conn
    |> put_flash(:info, "Key revoked. Clients using it will get 401 from now on.")
    |> redirect(to: "/admin")
  end

  # ---- rendering (plain HTML; user input is escaped) ----------------------------------------

  defp page(conn, tokens, new_token) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    body = """
    <h1>API keys</h1>
    <p class="lead">Bearer keys for the OpenAI-compatible front door. A key's plaintext is
    shown exactly once, right after it is created.</p>

    #{reveal(new_token)}

    <h2>Issue a key</h2>
    <form method="post" action="/admin/tokens" class="form-row">
      <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
      <input type="text" name="label" placeholder="label (e.g. laptop-cli, staging)"
             aria-label="Key label" required>
      <button type="submit" class="btn-primary">Create key</button>
    </form>

    <h2>Existing keys</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Label</th><th>Created</th><th>Last used</th><th>Status</th><th></th></tr></thead>
        <tbody>#{rows(tokens, csrf)}</tbody>
      </table>
    </div>
    """

    AdminLayout.page(conn, title: "API keys", active: :tokens, body: body)
  end

  defp reveal(nil), do: ""

  defp reveal(token) do
    """
    <div class="reveal">
      <strong>Copy this key now — it will not be shown again.</strong>
      <div class="reveal-key">
        <code id="new-key">#{esc(token)}</code>
        <button type="button" class="btn-primary btn-sm" id="copy-key">Copy</button>
      </div>
    </div>
    <script>
      document.getElementById('copy-key').addEventListener('click', function () {
        var btn = this;
        var key = document.getElementById('new-key').textContent.trim();
        navigator.clipboard.writeText(key).then(function () {
          btn.textContent = 'Copied ✓';
          setTimeout(function () { btn.textContent = 'Copy'; }, 1600);
        }, function () {
          // Clipboard API unavailable (http, old browser): select the key for manual copy.
          var range = document.createRange();
          range.selectNodeContents(document.getElementById('new-key'));
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        });
      });
    </script>
    """
  end

  defp rows([], _csrf),
    do: ~s(<tr><td colspan="5" class="muted">No keys yet — issue the first one above.</td></tr>)

  defp rows(tokens, csrf) do
    Enum.map_join(tokens, "", fn t ->
      status =
        if t.revoked_at,
          do: ~s(<span class="badge badge-danger">revoked</span>),
          else: ~s(<span class="badge badge-ok"><span class="dot"></span>active</span>)

      action =
        if t.revoked_at do
          ""
        else
          """
          <form class="inline" method="post" action="/admin/tokens/#{esc(t.id)}/revoke"
                onsubmit="return confirm('Revoke this key? Clients using it will get 401.')">
            <input type="hidden" name="_csrf_token" value="#{esc(csrf)}">
            <button type="submit" class="btn-danger btn-sm">Revoke</button>
          </form>
          """
        end

      """
      <tr>
        <td>#{esc(t.label)}<br><span class="muted">by #{esc(t.created_by || "—")}</span></td>
        <td>#{fmt_dt(t.inserted_at)}</td>
        <td>#{fmt_dt(t.last_used_at)}</td>
        <td>#{status}</td>
        <td class="num">#{action}</td>
      </tr>
      """
    end)
  end
end
