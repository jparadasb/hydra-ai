defmodule Coordinator.Repo.Migrations.ApiTokens do
  use Ecto.Migration

  def change do
    # Gateway API keys that authorize callers of the OpenAI-compatible front-door
    # (Coordinator.ApiRouter). These are NOT provider tokens — they only gate who may submit
    # jobs. We store the SHA-256 hash of each token, never the plaintext (shown once at
    # creation), so a DB/backup leak can't reveal a usable key.
    create table(:api_tokens, primary_key: false) do
      add :id, :string, primary_key: true
      add :label, :string, null: false
      add :token_hash, :string, null: false
      add :created_by, :string
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:revoked_at])
  end
end
