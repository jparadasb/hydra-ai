defmodule Coordinator.Jobs.JobRecord do
  @moduledoc "Persisted job + lease state. Carries no secrets."
  use Ecto.Schema
  import Ecto.Changeset

  alias Coordinator.Jobs.State

  @statuses ~w(pending leased awaiting_input done failed cancelled)
  @privacies ~w(public private sensitive local_only)

  @primary_key {:id, :string, autogenerate: false}
  schema "jobs" do
    field(:capability, :string)
    field(:privacy, :string, default: "local_only")
    field(:allow_external_providers, :boolean, default: false)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "pending")
    # Where inside `status` the job is. `status` stays the five-value column every
    # compare-and-swap in `Coordinator.Jobs` guards on; `state` is what a delegating agent polls
    # for. See `Coordinator.Jobs.State`.
    field(:state, :string, default: "queued")
    # Monotonic per lease generation; guards against a replayed or reordered progress frame.
    field(:progress_seq, :integer)
    field(:worker_id, :string)
    field(:lease_id, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:result, :map)
    # `updated_at` serves none of these: `renew_lease/3` bumps it every 20s, and retention and
    # the throughput chart both read it as "when the job finished".
    field(:leased_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:last_progress_at, :utc_datetime_usec)
    # When generation actually began, as opposed to when the job started running. Throughput is
    # measured from here; `started_at` includes loading the model, which on a local backend can
    # be most of a minute.
    field(:first_token_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    # What the worker actually used, which need not be what was requested.
    field(:actual_model, :string)
    field(:provider, :string)
    # Nil means the backend reported nothing — not a measured zero.
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    # A short code. This column is never redacted, so it must not carry caller content.
    field(:failure_reason, :string)
    # Who may read or cancel this job (`Coordinator.ApiAuth.caller_scope/1`), and the key that
    # makes a retried submission return the first job instead of buying a second one.
    field(:owner_scope, :string)
    field(:idempotency_key, :string)
    # Caller correlation data — the only new column that can hold caller content, so
    # `Coordinator.JobRetention` redacts it with the payload.
    field(:metadata, :map)
    field(:source, :string, default: "openai")
    # Set while the job is parked: what the model asked the caller for, and how many times it
    # has asked. `input_request` is caller-facing text, so retention drops it with the payload.
    field(:input_request, :map)
    field(:awaiting_input_until, :utc_datetime_usec)
    field(:last_worker_id, :string)
    field(:input_rounds, :integer, default: 0)
    # Ceiling on what this job may consume in total, across retries and resumed rounds. Nil is
    # unbounded. `priority` mirrors the Oban priority the caller asked for, so it is visible on
    # the row rather than only inside the queue.
    field(:max_total_tokens, :integer)
    field(:priority, :integer, default: 1)
    # When the prompt and completion were dropped by `Coordinator.JobRetention`. Nil means the
    # row still carries its text.
    field(:redacted_at, :utc_datetime_usec)
    # The gateway key that submitted this job. Nil when the door was open or the legacy env
    # master key was used — neither has an `api_tokens` row to point at.
    field(:api_token_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :capability,
      :privacy,
      :allow_external_providers,
      :payload,
      :status,
      :state,
      :progress_seq,
      :worker_id,
      :lease_id,
      :expires_at,
      :lease_expires_at,
      :attempts,
      :result,
      :api_token_id,
      :redacted_at,
      :leased_at,
      :started_at,
      :last_progress_at,
      :first_token_at,
      :finished_at,
      :actual_model,
      :provider,
      :input_tokens,
      :output_tokens,
      :failure_reason,
      :owner_scope,
      :idempotency_key,
      :metadata,
      :source,
      :input_request,
      :awaiting_input_until,
      :last_worker_id,
      :input_rounds,
      :max_total_tokens,
      :priority
    ])
    |> derive_state()
    |> validate_required([:id, :capability, :privacy, :status, :state])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:state, State.all())
    |> validate_inclusion(:privacy, @privacies)
    |> validate_state_pairing()
    |> unique_constraint([:owner_scope, :idempotency_key],
      name: :jobs_owner_scope_idempotency_key_index
    )
  end

  # `state` defaults to "queued", which is only right for a pending job — so a caller that sets
  # `status` alone would build an inconsistent row and be told off by the validation below for a
  # field it never mentioned. Derive it instead: naming a status and nothing else has exactly
  # one sensible answer. An explicitly contradictory pair is still an error.
  defp derive_state(changeset) do
    case {get_change(changeset, :status), get_change(changeset, :state)} do
      {status, nil} when is_binary(status) ->
        case State.states_for(status) do
          [state | _] -> put_change(changeset, :state, state)
          [] -> changeset
        end

      _ ->
        changeset
    end
  end

  # SQLite cannot express this as a table constraint, and it is the invariant that makes the
  # two-column design safe: a row whose `state` disagrees with its `status` would be read one
  # way by a lifecycle guard and reported another way to the caller.
  defp validate_state_pairing(changeset) do
    status = get_field(changeset, :status)
    state = get_field(changeset, :state)

    cond do
      is_nil(status) or is_nil(state) ->
        changeset

      State.consistent?(status, state) ->
        changeset

      true ->
        add_error(changeset, :state, "is not a valid state for status #{status}",
          status: status,
          state: state
        )
    end
  end
end
