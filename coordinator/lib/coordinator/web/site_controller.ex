defmodule Coordinator.Web.SiteController do
  @moduledoc """
  Serves the public landing page at "/". The page is a static HTML shell (priv/site/index.html)
  whose sibling assets — tailwind.css, logo.png — are served by `Plug.Static` on the endpoint.
  Download links self-update client-side from the GitHub releases API, so the shell never needs
  to be regenerated to stay current.

  Read once at startup and cached in the module; the file ships in the release under priv.
  """
  use Phoenix.Controller, formats: []

  @index Application.app_dir(:coordinator, "priv/site/index.html")
  @external_resource @index
  @html File.read!(@index)

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, @html)
  end
end
