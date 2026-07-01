defmodule Coordinator.WorkerKey do
  @moduledoc """
  A worker's pinned Ed25519 device public key (trust-on-first-use). Carries no secrets — the
  private key never leaves the worker. See `Coordinator.DeviceAuth`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(trusted revoked)

  @primary_key {:worker_id, :string, autogenerate: false}
  schema "worker_keys" do
    field(:public_key, :string)
    field(:status, :string, default: "trusted")
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:worker_id, :public_key, :status, :first_seen_at, :last_seen_at])
    |> validate_required([:worker_id, :public_key, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
