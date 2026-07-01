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
  @impl true
  def connect(params, socket, _connect_info) do
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

  # Anonymous socket: workers are identified by their channel topic, not a socket id.
  @impl true
  def id(_socket), do: nil
end
