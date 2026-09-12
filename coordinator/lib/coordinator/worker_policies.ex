defmodule Coordinator.WorkerPolicies do
  @moduledoc """
  Admin-controlled per-worker job policy, stored on the worker's `worker_keys` row.

  Both the privacy levels a worker may accept and its routing trust are decided **here**, not
  by the worker: every worker starts public-only and untrusted, and an admin raises either in
  `/admin/workers`. Whatever the worker declares in its registration payload is advisory and is
  overridden at registration time (`Coordinator.WorkerSession`).

  Trust matters because the router pays for it: `"trusted"` is worth a -20 score bonus, so a
  worker that could name its own trust level won essentially every routing decision against
  honest workers.
  """

  alias Coordinator.{Job, Repo, WorkerKey}

  @default_levels ["public"]
  @default_trust "untrusted"

  @doc "All enrolled workers (worker_keys rows), for the admin console."
  def list do
    import Ecto.Query, only: [from: 2]
    Repo.all(from(k in WorkerKey, order_by: k.worker_id))
  end

  @doc """
  The admin-granted privacy levels for `worker_id`. Public-only when the worker has no
  enrollment row (fail-safe default).
  """
  def accepted_levels(worker_id) when is_binary(worker_id) do
    case Repo.get(WorkerKey, worker_id) do
      %WorkerKey{accepted_job_levels: levels} when is_list(levels) and levels != [] -> levels
      _ -> @default_levels
    end
  end

  def accepted_levels(_), do: @default_levels

  @doc """
  The admin-granted routing trust for `worker_id`. Untrusted when the worker has no enrollment
  row (fail-safe default), which is also what an unenrolled worker gets.
  """
  def trust_level(worker_id) when is_binary(worker_id) do
    case Repo.get(WorkerKey, worker_id) do
      %WorkerKey{trust_level: trust} when is_binary(trust) and trust != "" -> trust
      _ -> @default_trust
    end
  end

  def trust_level(_), do: @default_trust

  @doc """
  Set an enrolled worker's routing trust. Applies immediately to the connected worker, the same
  way a privacy grant does.
  """
  def set_trust_level(worker_id, trust) when is_binary(trust) do
    case Repo.get(WorkerKey, worker_id) do
      nil ->
        {:error, :not_enrolled}

      %WorkerKey{} = key ->
        key
        |> WorkerKey.changeset(%{trust_level: trust})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              Coordinator.PubSub,
              "worker_control:#{worker_id}",
              {:set_trust_level, trust}
            )

            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Grant `levels` to an enrolled worker. Persists to `worker_keys` and applies immediately to
  the live registry entry if the worker is connected. Only enrolled (device-keyed) workers
  can be granted anything beyond the default.
  """
  def set_accepted_levels(worker_id, levels) when is_list(levels) do
    levels = if levels == [], do: @default_levels, else: levels

    case Repo.get(WorkerKey, worker_id) do
      nil ->
        {:error, :not_enrolled}

      %WorkerKey{} = key ->
        key
        |> WorkerKey.changeset(%{accepted_job_levels: levels})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            # Apply immediately to the connected worker wherever it is in the cluster: the
            # worker's channel process subscribes to this control topic and updates its
            # Presence snapshot. A worker that isn't connected picks the grant up at its next
            # registration (which reads this same row).
            parsed = Enum.map(levels, &Job.parse_privacy/1)

            Phoenix.PubSub.broadcast(
              Coordinator.PubSub,
              "worker_control:#{worker_id}",
              {:set_accepted_levels, parsed}
            )

            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end
end
