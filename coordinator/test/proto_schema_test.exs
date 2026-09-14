defmodule Coordinator.ProtoSchemaTest do
  @moduledoc """
  `proto/` is the contract between two codebases that share no code, and its hard invariant —
  no message carries a credential — has until now been enforced only by review. Each side tests
  its own serialization, but nothing tested the schemas themselves, so a new message could
  declare a secret-shaped field and both suites would stay green.
  """
  use ExUnit.Case, async: true

  @proto_dir Path.expand("../../proto", __DIR__)

  # The same vocabulary `Coordinator.SecretGuard` refuses on an inbound payload. A schema that
  # declares one of these is asking a worker to send exactly what the guard exists to stop.
  @banned ~w(token api_key apikey authorization auth secret password credential bearer x_api_key)

  defp schemas do
    @proto_dir
    |> Path.join("*.schema.json")
    |> Path.wildcard()
  end

  # Every property name anywhere in the schema, at any nesting depth.
  defp property_names(%{} = node) do
    own =
      case node["properties"] do
        %{} = props -> Map.keys(props)
        _ -> []
      end

    own ++ Enum.flat_map(Map.values(node), &property_names/1)
  end

  defp property_names(list) when is_list(list), do: Enum.flat_map(list, &property_names/1)
  defp property_names(_), do: []

  test "there is at least one schema to check" do
    # Guards the guard: a wildcard that matches nothing would make every test below vacuous.
    assert length(schemas()) >= 8
  end

  test "no wire schema declares a credential-shaped field" do
    for path <- schemas() do
      names = path |> File.read!() |> Jason.decode!() |> property_names()

      for name <- names, banned <- @banned do
        normalized = name |> String.downcase() |> String.replace("-", "_")

        refute normalized == banned or String.ends_with?(normalized, "_" <> banned),
               "#{Path.basename(path)} declares #{inspect(name)}, which is credential-shaped"
      end
    end
  end

  test "every schema is closed, so an unknown field is refused rather than ignored" do
    # `additionalProperties: false` is what makes the invariant above enforceable: without it a
    # sender can attach anything and the schema still says the message is valid.
    for path <- schemas() do
      schema = path |> File.read!() |> Jason.decode!()

      assert schema["additionalProperties"] == false,
             "#{Path.basename(path)} does not close its top level"
    end
  end

  test "token_storage is a label, and is the one allowed near-miss" do
    # Registration names *where* a token lives so the admin console can show it. It is not the
    # token, and the test above must not be loosened to a substring match that would let a real
    # credential field through under a similar name.
    registration =
      @proto_dir |> Path.join("registration.schema.json") |> File.read!() |> Jason.decode!()

    assert "token_storage" in property_names(registration)
    assert get_in(registration, ["properties", "provider", "properties", "token_storage", "enum"])
  end
end
