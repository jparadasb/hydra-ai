defmodule Coordinator.WorkerKey do
  @moduledoc """
  A worker's pinned Ed25519 device public key (trust-on-first-use) plus the admin-granted
  job policy for that worker. Carries no secrets — the private key never leaves the worker.
  See `Coordinator.DeviceAuth` (enrollment) and `Coordinator.WorkerPolicies` (policy).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(trusted revoked)
  @privacy_levels ~w(public private sensitive local_only)

  @primary_key {:worker_id, :string, autogenerate: false}
  schema "worker_keys" do
    field(:public_key, :string)
    field(:status, :string, default: "trusted")
    field(:accepted_job_levels, {:array, :string}, default: ["public"])
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def privacy_levels, do: @privacy_levels

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :worker_id,
      :public_key,
      :status,
      :accepted_job_levels,
      :first_seen_at,
      :last_seen_at
    ])
    |> validate_required([:worker_id, :public_key, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_subset(:accepted_job_levels, @privacy_levels)
  end
end
