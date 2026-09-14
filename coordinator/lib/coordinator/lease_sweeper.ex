defmodule Coordinator.LeaseSweeper do
  @moduledoc """
  Recovers jobs that stopped moving.

  Two questions, both asked every minute. A `leased` job whose deadline passed has a worker that
  did not deliver — reclaim it and try again. An `awaiting_input` job whose deadline passed has
  a *caller* that did not answer, which is not a retry: asking the same unanswered question
  again would change nothing. That one fails outright.

  The second question is a privacy requirement as much as a liveness one. A parked job is not
  terminal, so `Coordinator.JobRetention` leaves it alone — a job nobody ever answers would be
  the caller's prompt sitting in the database indefinitely.
  """
  use Oban.Worker, queue: :leases, max_attempts: 3, unique: [period: 50]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with :ok <- Coordinator.Jobs.reclaim_expired_leases() do
      Coordinator.Jobs.fail_unanswered_input()
    end
  end
end
