defmodule Coordinator.Repo.Migrations.JobIndexesAndRetention do
  use Ecto.Migration

  def change do
    # The dashboard's throughput query filters `status in (...) and updated_at > ?` every poll.
    # With only `index(:jobs, [:status])` that degraded with total job count rather than with
    # recent activity.
    create index(:jobs, [:status, :updated_at])

    # "What has this worker been given" — the lease sweeper and the admin worker view both ask.
    create index(:jobs, [:worker_id])

    # Retention scans and "recent jobs" listings order by arrival.
    create index(:jobs, [:inserted_at])

    # When the prompt and completion were dropped from a row. Retention keeps the job's
    # metadata (status, timings, attribution) long after the text is gone, so this has to be
    # distinguishable from "a job that never had a payload".
    alter table(:jobs) do
      add :redacted_at, :utc_datetime_usec
    end
  end
end
