defmodule Coordinator.ApiToken do
  @moduledoc """
  A gateway API key for the OpenAI-compatible front-door (`Coordinator.ApiRouter`).

  Carries no provider secret — it only authorizes *who may submit jobs*. Only the SHA-256
  `token_hash` is persisted; the plaintext is shown once at creation and never stored. See
  `Coordinator.ApiTokens`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "api_tokens" do
    field(:label, :string)
    field(:token_hash, :string)
    field(:created_by, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:id, :label, :token_hash, :created_by, :last_used_at, :revoked_at])
    |> validate_required([:id, :label, :token_hash])
    |> unique_constraint(:token_hash)
  end
end
