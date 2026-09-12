defmodule Coordinator.Jobs.JobRecord do
  @moduledoc "Persisted job + lease state. Carries no secrets."
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending leased done failed cancelled)
  @privacies ~w(public private sensitive local_only)

  @primary_key {:id, :string, autogenerate: false}
  schema "jobs" do
    field(:capability, :string)
    field(:privacy, :string, default: "local_only")
    field(:allow_external_providers, :boolean, default: false)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "pending")
    field(:worker_id, :string)
    field(:lease_id, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:result, :map)
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
      :worker_id,
      :lease_id,
      :expires_at,
      :lease_expires_at,
      :attempts,
      :result,
      :api_token_id,
      :redacted_at
    ])
    |> validate_required([:id, :capability, :privacy, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:privacy, @privacies)
  end
end
