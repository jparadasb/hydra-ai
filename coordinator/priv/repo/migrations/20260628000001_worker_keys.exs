defmodule Coordinator.Repo.Migrations.WorkerKeys do
  use Ecto.Migration

  def change do
    # Trust-on-first-use registry of worker device public keys. Pins the Ed25519 public key a
    # worker first presents to its (machine-derived) worker_id; later connects must match it.
    # No secrets here — only public keys + status.
    create table(:worker_keys, primary_key: false) do
      add :worker_id, :string, primary_key: true
      add :public_key, :string, null: false
      # trusted | revoked
      add :status, :string, null: false, default: "trusted"
      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:worker_keys, [:status])
  end
end
