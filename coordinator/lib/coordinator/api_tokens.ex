defmodule Coordinator.ApiTokens do
  @moduledoc """
  Issue, verify, and revoke gateway API keys for the front-door (`Coordinator.ApiRouter`).

  The plaintext key is generated here and returned exactly once (at creation); only its
  SHA-256 hash is stored. Verification hashes the presented bearer and looks the hash up, so
  a leaked database never yields a usable key. These keys are NOT provider tokens — they only
  authorize *who may submit jobs*.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Coordinator.{ApiToken, Repo}

  @prefix "hydra_sk_"

  # How stale `last_used_at` may get before a request pays for a write to refresh it.
  @touch_interval_seconds 60

  @doc """
  Mint a new key. Returns `{:ok, plaintext, record}` — `plaintext` is shown to the admin once
  and never persisted. `created_by` records which admin (GitHub login) minted it.
  """
  def create(label, created_by \\ nil) when is_binary(label) do
    plaintext = @prefix <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))

    attrs = %{
      "id" => "tok-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)),
      "label" => label,
      "token_hash" => hash(plaintext),
      "created_by" => created_by
    }

    with {:ok, record} <- %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
      {:ok, plaintext, record}
    end
  end

  @doc "All keys, newest first (hashes only — no plaintext exists to show)."
  def list do
    from(t in ApiToken, order_by: [desc: t.inserted_at]) |> Repo.all()
  end

  @doc "Revoke a key by id. A revoked key no longer authorizes requests."
  def revoke(id) do
    from(t in ApiToken, where: t.id == ^id and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  Verify a presented bearer token. Returns `{:ok, token_id}` for an active (non-revoked) key,
  else `{:error, :invalid}`. The id is the caller identity the front-door attributes the
  request to — it is what makes a job, a usage row, and a rate-limit bucket traceable to a key.
  Best-effort touches `last_used_at`. Ignores the legacy env master key — the caller
  (`Coordinator.ApiRouter`) checks that separately.
  """
  def verify(presented) when is_binary(presented) do
    digest = hash(presented)

    case Repo.get_by(ApiToken, token_hash: digest) do
      %ApiToken{revoked_at: nil} = token ->
        touch(token)
        {:ok, token.id}

      _ ->
        {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}

  @doc "SHA-256 hex digest of a token. Public so tests and the router can hash consistently."
  def hash(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  # Record last use coarsely. Writing on *every* authenticated request costs one DB write per
  # request — on SQLite, one write lock per request — to refresh a field nobody reads at
  # sub-minute resolution. Skip the write while the stored value is still fresh, and guard it
  # on the value we read so concurrent requests for the same key collapse into one write
  # instead of each issuing their own.
  defp touch(%ApiToken{id: id, last_used_at: nil}) do
    # Pinning a nil into a comparison is what Ecto refuses, so first use gets its own clause.
    from(t in ApiToken, where: t.id == ^id and is_nil(t.last_used_at))
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])

    :ok
  rescue
    # Best-effort bookkeeping: never fail a request over it, but do not hide a bug either.
    error -> Logger.warning("last_used_at touch failed: #{inspect(error)}")
  end

  defp touch(%ApiToken{id: id, last_used_at: last_used_at}) do
    now = DateTime.utc_now()

    if DateTime.diff(now, last_used_at, :second) >= @touch_interval_seconds do
      from(t in ApiToken, where: t.id == ^id and t.last_used_at == ^last_used_at)
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  rescue
    # Best-effort bookkeeping: never fail a request over it, but do not hide a bug either.
    error -> Logger.warning("last_used_at touch failed: #{inspect(error)}")
  end
end
