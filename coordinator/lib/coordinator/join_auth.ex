defmodule Coordinator.JoinAuth do
  @moduledoc """
  Shared-secret authentication for worker WebSocket connections.

  The expected token is `HYDRA_JOIN_TOKEN`, wired into application env in `runtime.exs`.
  Workers present it as the `token` connect param (query string). The comparison is
  constant-time.

  When no token is configured the coordinator is **open** — acceptable for a loopback dev
  box, but NOT for a publicly-tunneled deployment. This is distinct from provider tokens,
  which never reach the coordinator at all.
  """

  @doc "Is a join token configured (i.e. are connections required to authenticate)?"
  def required?, do: configured() not in [nil, ""]

  @doc """
  Check a connect-params map. Returns `:ok` when no token is configured (open) or when the
  presented `"token"` matches; `:error` otherwise.
  """
  def verify(params) when is_map(params) do
    case configured() do
      token when token in [nil, ""] ->
        :ok

      token ->
        presented = params["token"] || ""
        if Plug.Crypto.secure_compare(token, presented), do: :ok, else: :error
    end
  end

  defp configured, do: Application.get_env(:coordinator, :join_token)
end
