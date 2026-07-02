defmodule Coordinator.WorkerPolicies do
  @moduledoc """
  Admin-controlled per-worker job policy, stored on the worker's `worker_keys` row.

  The privacy levels a worker may accept are decided **here**, not by the worker: every
  worker starts public-only, and an admin raises it in `/admin/workers`. Whatever the worker
  declares in its registration payload is advisory and is overridden at registration time
  (`Coordinator.WorkerSession`).
  """

  alias Coordinator.{Repo, WorkerKey, WorkerRegistry}

  @default_levels ["public"]

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
            WorkerRegistry.update_accepted_levels(worker_id, levels)
            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end
end
