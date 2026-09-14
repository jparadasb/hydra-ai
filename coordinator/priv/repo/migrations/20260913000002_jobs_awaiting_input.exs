defmodule Coordinator.Repo.Migrations.JobsAwaitingInput do
  use Ecto.Migration

  @moduledoc """
  A job can now stop and wait for its caller.

  `awaiting_input` is a new `status`, not a new `state`, and that is the whole design. The lease
  sweeper reclaims rows where `status == "leased"`, so a parked job simply stops matching it —
  no NULL lease deadline, no attempt spent, no special case inside the reclaim path. Keeping it
  `leased` with a far-future deadline was the alternative, and it is fragile: the sweeper is the
  only thing that recovers a wedged worker, so pushing its deadline out to cover a parked job
  would leave a genuinely dead worker's job stranded for just as long.
  """

  def change do
    alter table(:jobs) do
      # What the model asked for, and which round it belongs to. Caller-facing, so redaction
      # drops it with the payload.
      add :input_request, :map

      # When waiting stops being reasonable. Not a nicety: a parked job is not terminal, so
      # JobRetention skips it — without a deadline, a job nobody answers is prompt text that is
      # never redacted.
      add :awaiting_input_until, :utc_datetime_usec

      # Which worker parked it, so the resumed job can prefer the one whose cache is warm.
      add :last_worker_id, :string

      # Bounds a model that asks in a loop. Distinct from `attempts`, which counts failures.
      add :input_rounds, :integer, null: false, default: 0
    end

    # The sweeper's second question, alongside expired leases.
    create index(:jobs, [:status, :awaiting_input_until])
  end
end
