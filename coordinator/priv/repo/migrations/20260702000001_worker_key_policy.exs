defmodule Coordinator.Repo.Migrations.WorkerKeyPolicy do
  use Ecto.Migration

  def change do
    alter table(:worker_keys) do
      # Admin-granted job privacy levels. Workers start public-only; an admin raises this
      # per worker in /admin/workers. Worker-declared levels are advisory only.
      add(:accepted_job_levels, {:array, :string}, default: ["public"], null: false)
    end
  end
end
