defmodule Coordinator.Repo.Migrations.CallerIdentityAndUsage do
  use Ecto.Migration

  def change do
    # Which gateway key submitted this job. Nullable: the door can be open (loopback dev) or
    # authorized by the legacy env master key, neither of which has an api_tokens row.
    alter table(:jobs) do
      add :api_token_id, :string
    end

    create index(:jobs, [:api_token_id])

    # Per-job token accounting. Workers report usage with every result and the coordinator used
    # to discard it, so there was no way to answer "which key consumed whose GPU" after the
    # fact. One row per completed job, attributed to the key that submitted it.
    create table(:usage_records, primary_key: false) do
      add :id, :string, primary_key: true
      add :job_id, :string, null: false
      add :api_token_id, :string
      add :worker_id, :string
      add :model, :string
      add :status, :string
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :total_tokens, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # A job produces exactly one usage row; a retried result must not double-count.
    create unique_index(:usage_records, [:job_id])
    # The accounting query: one key's consumption over a time window.
    create index(:usage_records, [:api_token_id, :inserted_at])
    create index(:usage_records, [:worker_id])
  end
end
