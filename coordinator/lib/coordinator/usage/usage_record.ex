defmodule Coordinator.Usage.UsageRecord do
  @moduledoc """
  One completed job's token accounting, attributed to the gateway key that submitted it.

  Carries no prompt text and no provider secret — only counts, the model name, and the ids
  needed to answer "which key consumed whose GPU". See `Coordinator.Usage`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "usage_records" do
    field(:job_id, :string)
    field(:api_token_id, :string)
    field(:worker_id, :string)
    field(:model, :string)
    field(:status, :string)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:total_tokens, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :job_id,
      :api_token_id,
      :worker_id,
      :model,
      :status,
      :input_tokens,
      :output_tokens,
      :total_tokens
    ])
    |> validate_required([:id, :job_id])
    |> unique_constraint(:job_id)
  end
end
