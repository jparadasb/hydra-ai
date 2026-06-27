defmodule Coordinator.WorkerSession do
  @moduledoc """
  The worker↔coordinator channel boundary, as pure functions so the contract is testable
  without a running Phoenix endpoint.

  A `WorkerChannel` (Phoenix.Channel) is a thin wrapper:

      def join("worker:" <> _id, payload, socket) do
        case Coordinator.WorkerSession.handle_register(payload, socket.transport_pid) do
          {:ok, worker} -> {:ok, assign(socket, :worker_id, worker.worker_id)}
          {:error, reason} -> {:error, %{reason: reason}}
        end
      end

      def handle_in("usage", payload, socket), do: ...WorkerSession.handle_usage(payload)...
      def handle_in("result", payload, socket), do: ...WorkerSession.handle_result(payload)...

  Every inbound payload passes through `Coordinator.SecretGuard.verify/1` first; a worker
  that tries to push a token is refused, never registered.
  """

  alias Coordinator.{SecretGuard, WorkerRegistry}

  @doc """
  Handle a worker's registration. Rejects any payload carrying secret-shaped data, then
  sanitizes (belt and suspenders) and registers the worker, monitoring `pid`.
  """
  def handle_register(payload, pid \\ nil, registry \\ WorkerRegistry) do
    with :ok <- SecretGuard.verify(payload),
         :ok <- validate_registration(payload) do
      sanitized = SecretGuard.sanitize(payload)
      WorkerRegistry.register(registry, sanitized, pid)
    end
  end

  @doc "Handle an aggregated usage report (no secrets). Returns the sanitized report."
  def handle_usage(payload) do
    case SecretGuard.verify(payload) do
      :ok -> {:ok, SecretGuard.sanitize(payload)}
      {:error, _} = err -> err
    end
  end

  @doc "Handle a normalized job result from a worker."
  def handle_result(payload) do
    case SecretGuard.verify(payload) do
      :ok -> {:ok, SecretGuard.sanitize(payload)}
      {:error, _} = err -> err
    end
  end

  defp validate_registration(%{"worker_id" => id, "execution_mode" => mode})
       when is_binary(id) and mode in ["local_model", "external_provider", "both"],
       do: :ok

  defp validate_registration(_), do: {:error, :invalid_registration}
end
