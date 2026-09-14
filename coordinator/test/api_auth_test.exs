defmodule Coordinator.ApiAuthTest do
  use ExUnit.Case, async: true

  alias Coordinator.ApiAuth

  describe "caller_scope/1" do
    test "distinguishes an identified key from an anonymous peer" do
      # This string is what a job row is owned by and what an idempotency key is scoped to, so
      # two different callers must never produce the same one — otherwise one caller can read,
      # cancel, or collide with another's job.
      assert ApiAuth.caller_scope(%{token_id: "tok_1", key: {:token, "tok_1"}}) == "tok:tok_1"
      assert ApiAuth.caller_scope(%{token_id: nil, key: {:ip, "10.0.0.1"}}) == "ip:10.0.0.1"

      refute ApiAuth.caller_scope(%{token_id: "a", key: {:token, "a"}}) ==
               ApiAuth.caller_scope(%{token_id: nil, key: {:ip, "a"}})
    end
  end
end
