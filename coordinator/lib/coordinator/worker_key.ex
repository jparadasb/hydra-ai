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
  # Routing trust. Admin-granted: a worker's own claim about this is advisory, like its
  # privacy levels. Ordered least to most preferred by the router's scoring.
  @trust_levels ~w(untrusted organization internal trusted)

  @primary_key {:worker_id, :string, autogenerate: false}
  schema "worker_keys" do
    field(:public_key, :string)
    field(:status, :string, default: "trusted")
    field(:accepted_job_levels, {:array, :string}, default: ["public"])
    field(:trust_level, :string, default: "untrusted")
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def privacy_levels, do: @privacy_levels
  def trust_levels, do: @trust_levels

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :worker_id,
      :public_key,
      :status,
      :accepted_job_levels,
      :trust_level,
      :first_seen_at,
      :last_seen_at
    ])
    |> validate_required([:worker_id, :public_key, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_subset(:accepted_job_levels, @privacy_levels)
    |> validate_inclusion(:trust_level, @trust_levels)
  end
end
