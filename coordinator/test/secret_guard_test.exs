defmodule Coordinator.SecretGuardTest do
  use ExUnit.Case, async: true
  alias Coordinator.SecretGuard

  test "verify rejects a banned key anywhere in the payload" do
    assert {:error, :secret_key_present} =
             SecretGuard.verify(%{"worker_id" => "w1", "provider" => %{"token" => "sk-abc12345"}})

    assert {:error, :secret_key_present} =
             SecretGuard.verify(%{"headers" => [%{"authorization" => "x"}]})
  end

  test "verify rejects a secret-shaped value even under an innocuous key" do
    assert {:error, :secret_value_present} =
             SecretGuard.verify(%{"note" => "my key is sk-ant-abcdef123456 ok"})

    assert {:error, :secret_value_present} =
             SecretGuard.verify(%{"x" => "AIzaSyABCDEFGHIJKLMNO"})
  end

  test "verify passes a clean registration" do
    reg = %{
      "worker_id" => "w1",
      "execution_mode" => "external_provider",
      "provider" => %{"name" => "openai", "api_type" => "openai_compatible"},
      "models" => [
        %{
          "name" => "gpt-4.1-mini",
          "capabilities" => ["text.clean"],
          "uses_external_provider" => true
        }
      ]
    }

    assert :ok = SecretGuard.verify(reg)
  end

  test "sanitize strips banned keys and redacts secret values" do
    dirty = %{
      "worker_id" => "w1",
      "api_key" => "sk-leak",
      "nested" => %{"authorization" => "Bearer abc", "keep" => "note sk-ant-zzzz9999 end"}
    }

    clean = SecretGuard.sanitize(dirty)
    refute Map.has_key?(clean, "api_key")
    refute Map.has_key?(clean["nested"], "authorization")
    assert clean["nested"]["keep"] == "note [REDACTED] end"
    assert clean["worker_id"] == "w1"
  end
end
