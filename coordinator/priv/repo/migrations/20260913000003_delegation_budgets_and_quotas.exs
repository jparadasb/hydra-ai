defmodule Coordinator.Repo.Migrations.DelegationBudgetsAndQuotas do
  use Ecto.Migration

  @moduledoc """
  Two ceilings, for two different runaways.

  A quota bounds a *key* over time: an agent left running overnight in a retry loop should not
  be able to consume a month of GPU. A budget bounds a *job*: a delegated job that can pause and
  resume is the first kind of job here that can grow without failing, so the thing that stops a
  loop cannot be the retry counter.
  """

  def change do
    alter table(:api_tokens) do
      # Nil means unlimited, which is what every existing key is — a quota nobody set must not
      # start refusing work.
      add :monthly_token_limit, :integer
    end

    alter table(:jobs) do
      # Nil means unbounded. Checked when a result lands, so a job cannot be requeued or resumed
      # past its budget; a single runaway generation is the worker's own limits to enforce.
      add :max_total_tokens, :integer
      # Oban's own priority, mirrored here so the value a caller asked for is visible on the row
      # rather than only inside the queue.
      add :priority, :integer, null: false, default: 1
    end
  end
end
