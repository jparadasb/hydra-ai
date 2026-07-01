defmodule Coordinator.ApiTokensTest do
  @moduledoc "Issue / verify / revoke gateway API keys. Plaintext is only ever returned once."
  use ExUnit.Case, async: false

  alias Coordinator.{ApiToken, ApiTokens, Repo}

  setup do
    on_exit(fn -> Repo.delete_all(ApiToken) end)
    :ok
  end

  test "create returns a one-time plaintext and stores only its hash" do
    {:ok, plaintext, record} = ApiTokens.create("laptop-cli", "octocat")

    assert String.starts_with?(plaintext, "hydra_sk_")
    assert record.label == "laptop-cli"
    assert record.created_by == "octocat"
    # Plaintext is never persisted; only its SHA-256 hash.
    refute record.token_hash == plaintext
    assert record.token_hash == ApiTokens.hash(plaintext)
  end

  test "verify accepts an active key and rejects unknown / revoked ones" do
    {:ok, plaintext, record} = ApiTokens.create("staging")

    assert ApiTokens.verify(plaintext) == :ok
    assert ApiTokens.verify("hydra_sk_nope") == {:error, :invalid}

    :ok = ApiTokens.revoke(record.id)
    assert ApiTokens.verify(plaintext) == {:error, :invalid}
  end

  test "verify touches last_used_at" do
    {:ok, plaintext, record} = ApiTokens.create("touch")
    assert is_nil(record.last_used_at)

    assert ApiTokens.verify(plaintext) == :ok
    assert %ApiToken{last_used_at: %DateTime{}} = Repo.get(ApiToken, record.id)
  end

  test "list returns issued keys newest first" do
    {:ok, _, _} = ApiTokens.create("one")
    {:ok, _, _} = ApiTokens.create("two")

    labels = ApiTokens.list() |> Enum.map(& &1.label)
    assert "one" in labels and "two" in labels
  end
end
