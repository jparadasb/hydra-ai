defmodule Coordinator.Repo.Migrations.JobFirstTokenAt do
  use Ecto.Migration

  @moduledoc """
  When a job produced its first token, as distinct from when it started running.

  Throughput was computed from `started_at`, which is the first progress frame — and the first
  frame is `loading_model`. On a local backend that loads a 35B model on demand, the load can be
  most of a minute, so a job generating at 20 tok/s reported 0.06 tok/s on its first frame and
  climbed for the rest of its life without ever reaching the truth.

  That is not a cosmetic difference: a delegating agent watching a healthy job produce what looks
  like a token every sixteen seconds has every reason to cancel it.
  """

  def change do
    alter table(:jobs) do
      add :first_token_at, :utc_datetime_usec
    end
  end
end
