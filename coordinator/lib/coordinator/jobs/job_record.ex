defmodule Coordinator.Jobs.JobRecord do
  @moduledoc "Persisted job + lease state. Carries no secrets."
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending leased done failed)
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
    field(:attempts, :integer, default: 0)
    field(:result, :map)

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
      :attempts,
      :result
    ])
    |> validate_required([:id, :capability, :privacy, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:privacy, @privacies)
  end
end
