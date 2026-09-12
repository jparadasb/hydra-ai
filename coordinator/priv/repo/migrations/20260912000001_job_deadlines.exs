defmodule Coordinator.Repo.Migrations.JobDeadlines do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add(:expires_at, :utc_datetime_usec)
      add(:lease_expires_at, :utc_datetime_usec)
    end

    create(index(:jobs, [:lease_expires_at]))
    create(index(:jobs, [:worker_id, :status]))
  end
end
