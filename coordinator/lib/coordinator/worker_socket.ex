defmodule Coordinator.WorkerSocket do
  @moduledoc """
  The worker WebSocket. Each worker joins its own `worker:<worker_id>` channel topic; the
  coordinator leases jobs by broadcasting a `"job"` event on that topic.
  """
  use Phoenix.Socket

  channel("worker:*", Coordinator.WorkerChannel)

  # Authenticate the connection before any topic is joined. Two mechanisms:
  #
  #   * Device key (preferred): the worker presents an Ed25519 signature over its identity;
  #     verified + pinned trust-on-first-use (`Coordinator.DeviceAuth`). The authenticated
  #     worker_id is bound to the socket so the channel can enforce it.
  #   * Shared join token (fallback): `Coordinator.JoinAuth`. Open if none configured.
  #
  # Set `HYDRA_REQUIRE_DEVICE_AUTH=true` to reject any worker that does not present a device
  # key (recommended for a public coordinator).
  # The peer address is also bound to the socket (`:peer_ip`) so a misbehaving worker can be
  # traced back to a host. It is evidence for an operator, never an authorization input —
  # identity comes from the device key.
  @impl true
  def connect(params, socket, connect_info) do
    socket = assign(socket, :peer_ip, peer_ip(connect_info))

    cond do
      Coordinator.DeviceAuth.present?(params) ->
        case Coordinator.DeviceAuth.verify(params) do
          {:ok, worker_id} -> {:ok, assign(socket, :auth_worker_id, worker_id)}
          {:error, _reason} -> :error
        end

      Application.get_env(:coordinator, :require_device_auth, false) ->
        :error

      true ->
        case Coordinator.JoinAuth.verify(params) do
          :ok -> {:ok, socket}
          :error -> :error
        end
    end
  end

  # Behind an ingress the TCP peer is the proxy, so prefer the first hop of `x-forwarded-for`
  # when one is present. Returns nil when the transport gave us neither (e.g. a test socket).
  defp peer_ip(connect_info) do
    forwarded =
      connect_info
      |> Map.get(:x_headers, [])
      |> Enum.find_value(fn
        {"x-forwarded-for", value} -> value |> String.split(",") |> List.first() |> String.trim()
        _ -> nil
      end)

    case {forwarded, connect_info} do
      {ip, _} when is_binary(ip) and ip != "" -> ip
      {_, %{peer_data: %{address: address}}} -> address |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end

  # Anonymous socket: workers are identified by their channel topic, not a socket id.
  @impl true
  def id(_socket), do: nil
end
