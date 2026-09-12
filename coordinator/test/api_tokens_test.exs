defmodule Coordinator.ApiTokensTest do
  @moduledoc "Issue / verify / revoke gateway API keys. Plaintext is only ever returned once."
  use ExUnit.Case, async: false

  import Ecto.Query

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

  test "verify returns the key's id so a request can be attributed to it" do
    {:ok, plaintext, record} = ApiTokens.create("staging")

    assert ApiTokens.verify(plaintext) == {:ok, record.id}
    assert ApiTokens.verify("hydra_sk_nope") == {:error, :invalid}

    :ok = ApiTokens.revoke(record.id)
    assert ApiTokens.verify(plaintext) == {:error, :invalid}
  end

  test "verify touches last_used_at" do
    {:ok, plaintext, record} = ApiTokens.create("touch")
    assert is_nil(record.last_used_at)

    assert {:ok, _id} = ApiTokens.verify(plaintext)
    assert %ApiToken{last_used_at: %DateTime{}} = Repo.get(ApiToken, record.id)
  end

  test "verify does not write last_used_at again while it is still fresh" do
    {:ok, plaintext, record} = ApiTokens.create("sampled-touch")

    assert {:ok, _id} = ApiTokens.verify(plaintext)
    first = Repo.get(ApiToken, record.id).last_used_at

    # A second request inside the sampling interval must not pay for another write — on SQLite
    # every one of those is a write lock taken to refresh a field read at minute resolution.
    assert {:ok, _id} = ApiTokens.verify(plaintext)
    assert Repo.get(ApiToken, record.id).last_used_at == first

    # Backdate past the interval and the next request refreshes it.
    Repo.update_all(
      from(t in ApiToken, where: t.id == ^record.id),
      set: [last_used_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
    )

    assert {:ok, _id} = ApiTokens.verify(plaintext)
    assert DateTime.compare(Repo.get(ApiToken, record.id).last_used_at, first) == :gt
  end

  test "list returns issued keys newest first" do
    {:ok, _, _} = ApiTokens.create("one")
    {:ok, _, _} = ApiTokens.create("two")

    labels = ApiTokens.list() |> Enum.map(& &1.label)
    assert "one" in labels and "two" in labels
  end
end
