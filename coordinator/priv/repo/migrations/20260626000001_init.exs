defmodule Coordinator.Repo.Migrations.Init do
  use Ecto.Migration

  def up do
    create table(:jobs, primary_key: false) do
      add :id, :string, primary_key: true
      add :capability, :string, null: false
      add :privacy, :string, null: false, default: "local_only"
      add :allow_external_providers, :boolean, null: false, default: false
      add :payload, :map, null: false, default: %{}
      # pending | leased | done | failed
      add :status, :string, null: false, default: "pending"
      add :worker_id, :string
      add :lease_id, :string
      add :attempts, :integer, null: false, default: 0
      add :result, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:jobs, [:status])

    # Oban (Lite engine) tables.
    Oban.Migration.up()
  end

  def down do
    Oban.Migration.down()
    drop table(:jobs)
  end
end
