defmodule Arbor.LLM.SensitivityCarrySecurityRegressionTest do
  @moduledoc """
  Security regression: source projection joins every recorded classification
  and refuses malformed present labels before a producer drops rich metadata.

  These public facade tests exercise deterministic production classification.
  Separate dispatch regressions prove the real transport admission boundary.
  """
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.LLM
  alias Arbor.LLM.{Message, Request}

  @moduletag :fast

  test "security regression: atom and string sensitivity aliases join to the higher floor" do
    for source <- [
          %{:sensitivity => :public, "sensitivity" => "restricted"},
          %{:sensitivity => :restricted, "sensitivity" => "public"}
        ] do
      assert {:ok, opts} = LLM.carry_sensitivity(source, [])
      assert Keyword.fetch!(opts, :sensitivity) == :restricted
    end
  end

  test "security regression: atom and string taint aliases both contribute their source floor" do
    source = %{:taint => taint(:public), "taint" => taint(:restricted)}

    assert {:ok, opts} = LLM.carry_sensitivity(source, [])
    assert Keyword.fetch!(opts, :sensitivity) == :restricted
  end

  test "security regression: an explicit absent sentinel is an invalid present classification" do
    for source <- [%{sensitivity: :absent}, %{"sensitivity" => :absent}] do
      assert {:error, {:sensitivity_blocked, _reason}} = LLM.carry_sensitivity(source, [])
    end
  end

  test "security regression: tainted inventory tuples retain restricted prose labels" do
    source =
      {"record", TaintedValue.wrap("An ordinary internal decision.", taint(:restricted)),
       :verified}

    assert {:ok, opts} = LLM.carry_sensitivity([source], [])
    assert Keyword.fetch!(opts, :sensitivity) == :restricted
  end

  test "security regression: request tool and provider-option labels survive projection" do
    for request <- [
          %Request{
            messages: [Message.new(:user, "An ordinary prompt.")],
            tools: [
              %{
                name: "lookup",
                description: "An ordinary description.",
                taint: taint(:restricted)
              }
            ]
          },
          %Request{
            messages: [Message.new(:user, "An ordinary prompt.")],
            provider_options: %{metadata: %{taint: taint(:restricted)}}
          }
        ] do
      assert {:ok, opts} = LLM.carry_sensitivity(request, [])
      assert Keyword.fetch!(opts, :sensitivity) == :restricted
    end
  end

  test "security regression: schema property names are data while explicit source metadata remains a floor" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "sensitivity" => %{"type" => "string"},
        "taint" => %{"type" => "object"},
        "nested" => %{
          "type" => "object",
          "properties" => %{"sensitivity" => %{"type" => "string"}}
        }
      }
    }

    assert {:ok, public_opts} = LLM.carry_sensitivity(schema, [])
    assert Keyword.fetch!(public_opts, :sensitivity) == :public

    classified = Map.put(schema, "metadata", %{"taint" => taint(:restricted)})
    assert {:ok, restricted_opts} = LLM.carry_sensitivity(classified, [])
    assert Keyword.fetch!(restricted_opts, :sensitivity) == :restricted
  end

  test "security regression: transmitted map keys are scanned for credential bytes" do
    key = "-----BEGIN PRIVATE KEY-----\nfixture material\n-----END PRIVATE KEY-----"

    assert {:ok, opts} = LLM.carry_sensitivity(%{key => "An ordinary value."}, [])
    assert Keyword.fetch!(opts, :sensitivity) == :restricted
  end

  test "security regression: invalid public taint cannot masquerade as valid classification" do
    for invalid <- [
          %{sensitivity: :public},
          %{sensitivity: :public, level: :bogus},
          Map.put(Map.from_struct(taint(:public)), :sanitizations, -1)
        ] do
      assert {:error, {:sensitivity_blocked, _reason}} =
               LLM.carry_sensitivity("An ordinary prompt.", taint: invalid)
    end
  end

  test "security regression: valid taint structs, maps and supported wrappers retain their floor" do
    restricted = taint(:restricted)
    {:ok, envelope} = TaintEnvelope.new("An ordinary internal decision.", restricted)
    {:ok, persisted_envelope} = TaintEnvelope.to_map(envelope)

    string_map =
      Map.new(Map.from_struct(restricted), fn {key, value} -> {Atom.to_string(key), value} end)

    for source <- [
          restricted,
          Map.from_struct(restricted),
          string_map,
          TaintedValue.wrap("An ordinary internal decision.", restricted),
          envelope,
          persisted_envelope
        ] do
      assert {:ok, opts} = LLM.carry_sensitivity("An ordinary prompt.", taint: source)
      assert Keyword.fetch!(opts, :sensitivity) == :restricted
    end
  end

  test "security regression: supported legacy trust atoms conservatively remain restricted" do
    for legacy <- [:trusted, :derived, :untrusted, :hostile] do
      assert {:ok, opts} = LLM.carry_sensitivity("An ordinary prompt.", taint: legacy)
      assert Keyword.fetch!(opts, :sensitivity) == :restricted
    end
  end

  defp taint(sensitivity) do
    %Taint{
      level: :derived,
      sensitivity: sensitivity,
      confidence: :verified,
      sanitizations: 0,
      source: "memory",
      chain: []
    }
  end
end
