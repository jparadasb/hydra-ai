defmodule Coordinator.Repo.Migrations.JobStateTimingsAndOwnership do
  use Ecto.Migration

  @moduledoc """
  Make a running job legible from the row alone, and give it an owner.

  Issue #85 turns Hydra into something an agent delegates to and walks away from. That needs
  three things the `jobs` table could not answer: where inside its status a job actually is,
  what it has produced so far, and who is allowed to ask.

  Everything here is a column rather than a `job_progress` side table. Progress is a latest
  value, not a time series: a side table would cost an upsert, a join on every read, and a
  second retention and deletion path (there are no foreign keys in this schema, so
  `Coordinator.JobRetention` would orphan its rows) in exchange for history nothing asks for.
  SQLite has exactly one writer, so one `UPDATE ... WHERE id = ?` on the primary key is the
  cheapest write available — and keeping the metrics on the job row is what lets a cancelled
  job retain its partial counts for free.
  """

  def change do
    alter table(:jobs) do
      # Where inside `status` the job is. See `Coordinator.Jobs.State` for why this is a second
      # column rather than more values on `status`. SQLite requires a default when adding a
      # NOT NULL column, and it cannot ALTER TABLE ADD CONSTRAINT, so the legal set is enforced
      # in the changeset exactly as `status` already is.
      add :state, :string, null: false, default: "queued"

      # Monotonic per lease generation. A progress frame older than the one already recorded is
      # a replay or a reorder and must not overwrite a newer count.
      add :progress_seq, :integer

      # `updated_at` cannot serve as any of these: `renew_lease/3` bumps it every 20s, and
      # `JobRetention`/`Stats` both read it as "when the job finished".
      add :leased_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :last_progress_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      # What the worker actually used, which is not necessarily what was requested.
      add :actual_model, :string
      add :provider, :string

      # Nullable on purpose: nil means the backend reported nothing, which is different from a
      # measured zero. The same distinction the worker already makes on `ResultUsage`.
      add :input_tokens, :integer
      add :output_tokens, :integer

      # A short code, never free text — this column is not redacted, so it must never be able
      # to carry caller content.
      add :failure_reason, :string

      # Who may read or cancel this job. "tok:<id>" for an admin-issued key, "ip:<addr>" for an
      # open or master-key door. Set on every job, from `Coordinator.ApiAuth.caller_scope/1`.
      add :owner_scope, :string

      # Caller-supplied, so a reconnecting agent can retry a submission without paying twice for
      # an expensive job.
      add :idempotency_key, :string

      # Caller correlation data. The only column added here that can hold caller content, so
      # `JobRetention` redacts it alongside the payload.
      add :metadata, :map

      add :source, :string, null: false, default: "openai"
    end

    # Scoped to the owner: two callers must be able to use the same key without colliding.
    # Both adapters treat NULL as distinct in a unique index, so jobs submitted without a key
    # never collide with each other and no partial index is needed.
    create unique_index(:jobs, [:owner_scope, :idempotency_key])

    # "What are my jobs, and how many of them are still open" — the ownership filter on every
    # read surface, and the per-key open-job ceiling on submission.
    create index(:jobs, [:owner_scope, :status])

    # Existing rows predate `state`, and the default put them all in "queued" regardless of
    # where they actually ended. Literal SQL so it runs identically on SQLite and Postgres.
    execute "UPDATE jobs SET state = 'completed' WHERE status = 'done'",
            "UPDATE jobs SET state = 'queued' WHERE status = 'done'"

    execute "UPDATE jobs SET state = 'failed' WHERE status = 'failed'",
            "UPDATE jobs SET state = 'queued' WHERE status = 'failed'"

    execute "UPDATE jobs SET state = 'cancelled' WHERE status = 'cancelled'",
            "UPDATE jobs SET state = 'queued' WHERE status = 'cancelled'"

    execute "UPDATE jobs SET state = 'leased' WHERE status = 'leased'",
            "UPDATE jobs SET state = 'queued' WHERE status = 'leased'"
  end
end
