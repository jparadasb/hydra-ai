defmodule Coordinator.SecretGuardTest do
  use ExUnit.Case, async: true
  alias Coordinator.SecretGuard

  describe "verify — the registration boundary, where rejecting is right" do
    test "rejects a banned key anywhere in the payload" do
      assert {:error, :secret_key_present} =
               SecretGuard.verify(%{
                 "worker_id" => "w1",
                 "provider" => %{"token" => "sk-abc12345678901234567"}
               })

      assert {:error, :secret_key_present} =
               SecretGuard.verify(%{"headers" => [%{"authorization" => "x"}]})
    end

    test "rejects a secret-shaped value even under an innocuous key" do
      assert {:error, :secret_value_present} =
               SecretGuard.verify(%{"note" => "my key is sk-ant-abcdef1234567890abcdef ok"})

      assert {:error, :secret_value_present} =
               SecretGuard.verify(%{"x" => "AIzaSyABCDEFGHIJKLMNOPQRST"})
    end

    test "passes a clean registration, including its token_storage field" do
      reg = %{
        "worker_id" => "w1",
        "execution_mode" => "external_provider",
        # `token_storage` contains "token" and is on every registration a provider worker
        # sends. Matching it would refuse every one of them.
        "provider" => %{
          "name" => "openai",
          "api_type" => "openai_compatible",
          "token_storage" => "local_encrypted"
        },
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

    test "recurses into tuples and structs instead of passing them as clean" do
      # A tuple's elements are values, not key/value pairs, so what is found inside one is a
      # secret *value*. Previously a tuple was simply not walked at all.
      assert {:error, :secret_value_present} =
               SecretGuard.verify(%{"pair" => {:note, "AIzaSyABCDEFGHIJKLMNOPQRST"}})

      assert {:error, :secret_value_present} =
               SecretGuard.verify([{"note", "AIzaSyABCDEFGHIJKLMNOPQRST"}])

      assert {:error, :secret_value_present} =
               SecretGuard.verify(%URI{
                 scheme: "https",
                 host: "example.com",
                 query: "key=AIzaSyABCDEFGHIJKLMNOPQRST"
               })
    end
  end

  describe "redact — the result boundary, where rejecting costs the caller their answer" do
    test "a completion that talks about auth headers survives with the credential removed" do
      # The regression: this whole result used to be dropped, and the caller got a 504 with
      # nothing to explain it.
      result = %{
        "job_id" => "j1",
        "status" => "ok",
        "output" => %{
          "content" => """
          Send your key in the header:

              Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz012345

          and the API will accept the request.
          """
        }
      }

      {clean, count} = SecretGuard.redact(result)

      assert count > 0
      content = clean["output"]["content"]
      refute content =~ "sk-abcdefghijklmnopqrstuvwxyz012345"
      # The answer is still an answer.
      assert content =~ "Authorization:"
      assert content =~ "the API will accept the request"
      assert clean["status"] == "ok"
      assert clean["job_id"] == "j1"
    end

    test "prose about bearer tokens is not mistaken for one" do
      result = %{"output" => %{"content" => "Use a Bearer token in the Authorization header."}}

      assert {clean, 0} = SecretGuard.redact(result)
      assert clean["output"]["content"] =~ "Bearer token"
    end

    test "a tool call keeps its arguments' shape, losing only the credential's value" do
      # Agent clients routinely emit an `authorization` header key in tool arguments. Dropping
      # the key changes the model's output; replacing the value does not.
      result = %{
        "output" => %{
          "tool_calls" => [
            %{
              "name" => "http_request",
              "arguments" => %{
                "url" => "https://api.example.com/v1/things",
                "method" => "GET",
                "headers" => %{"authorization" => "Bearer sk-abcdefghijklmnopqrstuvwxyz0123"}
              }
            }
          ]
        }
      }

      {clean, count} = SecretGuard.redact(result)

      assert count == 1
      [call] = clean["output"]["tool_calls"]
      headers = call["arguments"]["headers"]

      assert Map.has_key?(headers, "authorization")
      assert headers["authorization"] == "[REDACTED]"
      assert call["arguments"]["url"] == "https://api.example.com/v1/things"
      assert call["name"] == "http_request"
    end

    test "token counts are not credentials" do
      result = %{
        "status" => "ok",
        "usage" => %{
          "input_tokens" => 11,
          "output_tokens" => 7,
          "total_tokens" => 18,
          "max_tokens" => 512
        }
      }

      assert {clean, 0} = SecretGuard.redact(result)
      assert clean["usage"]["total_tokens"] == 18
    end

    test "redacts credential shapes the old prefix list missed" do
      # Assembled from parts rather than written out: a literal of this shape trips GitHub's
      # push protection, which would block the branch over a fixture that is not a real key.
      shapes = %{
        "aws" => "AKIA" <> "IOSFODNN7EXAMPLE",
        "github" => "ghp_" <> "abcdefghijklmnopqrstuvwxyz0123456789",
        "slack" => "xoxb-" <> "1234567890-abcdefghijkl",
        "stripe" => "sk_" <> "live_" <> "abcdefghijklmnopqrstuvwx",
        "jwt" =>
          "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      }

      {clean, count} = SecretGuard.redact(%{"output" => shapes})

      assert count == map_size(shapes)

      for {name, _} <- shapes do
        assert clean["output"][name] == "[REDACTED]", "#{name} was not redacted"
      end
    end

    test "redacts a PEM private key block whole" do
      pem = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAx0Z3bE1mQ1J1cmlvdXMgYnV0IG5vdCBhIHJlYWwga2V5Lg==
      -----END RSA PRIVATE KEY-----
      """

      {clean, count} = SecretGuard.redact(%{"note" => "here it is:\n" <> pem})

      assert count == 1
      refute clean["note"] =~ "MIIEow"
      assert clean["note"] =~ "here it is:"
    end

    test "an unrecognized credential shape is caught by length and entropy" do
      opaque = "Zx9Kq2LmP7wRt4Yv8Nb3Hc6Jd1Gf5Sa0"

      assert SecretGuard.opaque_secret?(opaque)

      assert {%{"key_material" => "[REDACTED]"}, 1} =
               SecretGuard.redact(%{"key_material" => opaque})
    end

    test "ordinary content is not mistaken for an opaque credential" do
      # Short identifiers, prose, and long blobs all sit outside the bounds on purpose: below
      # them are ids, above them are base64 images and document bodies.
      refute SecretGuard.opaque_secret?("job-4f2a9c")
      refute SecretGuard.opaque_secret?("the quick brown fox jumps over the lazy dog again")
      refute SecretGuard.opaque_secret?(String.duplicate("QUJDREVGR0hJSktMTU5PUFFSU1R", 20))
      refute SecretGuard.opaque_secret?("Coordinator.SecretGuard.opaque_secret?/1")
      # All one character class, so no matter how long: not a credential shape.
      refute SecretGuard.opaque_secret?(String.duplicate("a", 64))
    end

    test "redacts inside tuples and structs rather than passing them through" do
      assert {{:note, "[REDACTED]"}, 1} =
               SecretGuard.redact({:note, "AIzaSyABCDEFGHIJKLMNOPQRST"})

      {clean, count} = SecretGuard.redact(%{"pair" => {"a", "AIzaSyABCDEFGHIJKLMNOPQRST"}})
      assert count == 1
      assert clean["pair"] == {"a", "[REDACTED]"}

      # A struct keeps its type; only its fields are rewritten.
      {clean, 1} =
        SecretGuard.redact(%URI{
          scheme: "https",
          host: "example.com",
          query: "key=AIzaSyABCDEFGHIJKLMNOPQRST"
        })

      assert %URI{host: "example.com"} = clean
      # `query` is not a secret-shaped key, so the credential span inside it is replaced
      # rather than the whole value.
      assert clean.query == "key=[REDACTED]"
    end

    test "a URL is not mistaken for an opaque credential" do
      # Long, whitespace-free and high-entropy — the alphabet restriction is what excludes it.
      refute SecretGuard.opaque_secret?("https://api.example.com/v1/things/abc123")
      refute SecretGuard.opaque_secret?("/var/lib/hydra/coordinator.db.backup.20260912")
      refute SecretGuard.opaque_secret?("someone.longish@mail.example.com")
    end

    test "counts every redaction so a leaking worker is visible" do
      {_clean, count} =
        SecretGuard.redact(%{
          "a" => "AIzaSyABCDEFGHIJKLMNOPQRST",
          "b" => %{"authorization" => "Bearer xyz"},
          "c" => ["ghp_abcdefghijklmnopqrstuvwxyz0123456789"]
        })

      assert count == 3
    end

    test "an empty value under a secret key is left alone rather than counted" do
      assert {clean, 0} = SecretGuard.redact(%{"api_key" => nil, "token" => ""})
      assert clean["api_key"] == nil
      assert clean["token"] == ""
    end
  end

  describe "key matching" do
    test "catches the shapes whole-string matching missed" do
      for key <- ~w(openai_api_key access_token refresh_token client_secret api-key
                    x-api-key apiKey private_key AUTHORIZATION service_password) do
        assert {:error, :secret_key_present} = SecretGuard.verify(%{key => "value"}),
               "#{key} was not treated as a secret key"
      end
    end

    test "leaves ordinary keys alone" do
      for key <- ~w(worker_id model messages content role capabilities keyboard monkey
                    max_tokens token_storage total_tokens) do
        assert :ok = SecretGuard.verify(%{key => "value"}), "#{key} was treated as a secret"
      end
    end
  end

  describe "sanitize — registration only, where dropping a key is acceptable" do
    test "strips banned keys and redacts secret values" do
      dirty = %{
        "worker_id" => "w1",
        "api_key" => "sk-leak",
        "nested" => %{
          "authorization" => "Bearer abc",
          "keep" => "note sk-ant-zzzz9999888877776666 end"
        }
      }

      clean = SecretGuard.sanitize(dirty)
      refute Map.has_key?(clean, "api_key")
      refute Map.has_key?(clean["nested"], "authorization")
      assert clean["nested"]["keep"] == "note [REDACTED] end"
      assert clean["worker_id"] == "w1"
    end
  end
end
