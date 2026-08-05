defmodule Arbor.Contracts.Security.TaintEnvelopeTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @moduletag :fast

  defp taint(overrides \\ %{}) do
    struct(
      Taint,
      Map.merge(
        %{
          level: :untrusted,
          sensitivity: :confidential,
          sanitizations: 3,
          confidence: :verified,
          source: "voice",
          chain: ["ingress"]
        },
        overrides
      )
    )
  end

  defp payload do
    %{
      "z" => [%{"b" => true, "a" => nil}],
      "a" => "hello"
    }
  end

  test "constructs the exact closed persisted shape" do
    assert {:ok, envelope} = TaintEnvelope.new(payload(), taint())
    assert envelope.version == 1
    assert envelope.payload_encoding == "canonical_json_v1"
    assert {:ok, persisted} = TaintEnvelope.to_map(envelope)

    assert Map.keys(persisted) |> Enum.sort() ==
             ["payload_encoding", "payload_sha256", "taint", "version"]

    assert Map.keys(persisted["taint"]) |> Enum.sort() ==
             ["chain", "confidence", "level", "sanitizations", "sensitivity", "source"]

    assert persisted["taint"]["level"] == "untrusted"
    assert persisted["taint"]["sensitivity"] == "confidential"
    assert persisted["taint"]["confidence"] == "verified"
    assert is_binary(persisted["payload_sha256"])
    assert {:ok, ^envelope} = TaintEnvelope.decode_persisted(persisted)
  end

  test "canonical JSON is invariant to nested map order and atom scalar normalization" do
    first = %{"outer" => %{"b" => :value, "a" => true}}
    second = %{outer: %{a: true, b: "value"}}

    assert {:ok, first_json} = TaintEnvelope.canonical_json(first)
    assert {:ok, second_json} = TaintEnvelope.canonical_json(second)
    assert first_json == second_json
    assert Jason.decode!(first_json) == %{"outer" => %{"a" => true, "b" => "value"}}
  end

  test "orders canonical object keys by UTF-8 binary order, not RFC 8785" do
    assert {:ok, json} = TaintEnvelope.canonical_json(%{"é" => 1, "z" => 2})
    assert json == ~s({"z":2,"é":1})
  end

  test "rejects atom/string key alias collisions" do
    assert {:error, :payload_alias_collision} =
             TaintEnvelope.canonical_json(%{:name => "one", "name" => "two"})
  end

  test "hashes deterministically and detects changed payloads" do
    assert {:ok, first} = TaintEnvelope.new(payload(), taint())
    assert {:ok, second} = TaintEnvelope.new(payload(), taint())
    assert first.payload_sha256 == second.payload_sha256
    assert {:ok, persisted} = TaintEnvelope.to_map(first)
    assert {:ok, ^first} = TaintEnvelope.verify(persisted, payload())

    assert {:error, :payload_mismatch} =
             TaintEnvelope.verify(persisted, Map.put(payload(), "a", "changed"))
  end

  test "strict decode rejects unknown, extra, mixed, and malformed fields" do
    assert {:ok, envelope} = TaintEnvelope.new(payload(), taint())
    assert {:ok, valid} = TaintEnvelope.to_map(envelope)

    invalid = [
      Map.put(valid, "version", 2),
      Map.put(valid, "payload_encoding", "json"),
      Map.put(valid, "payload_sha256", String.duplicate("A", 64)),
      Map.put(valid, "extra", true),
      Map.put(valid, :version, valid["version"]),
      put_in(valid, ["taint", :level], "hostile"),
      put_in(valid, ["taint", "level"], :hostile),
      put_in(valid, ["taint", "source"], <<255>>),
      put_in(valid, ["taint", "chain"], List.duplicate("x", 17)),
      put_in(valid, ["taint", "chain"], ["x" | :improper_tail])
    ]

    for candidate <- invalid do
      assert {:error, _reason} = TaintEnvelope.decode_persisted(candidate)
    end
  end

  test "strict decode rejects every missing top-level and nested taint field" do
    assert {:ok, envelope} = TaintEnvelope.new(payload(), taint())
    assert {:ok, valid} = TaintEnvelope.to_map(envelope)

    for field <- ["version", "payload_encoding", "payload_sha256", "taint"] do
      assert {:error, _reason} = TaintEnvelope.decode_persisted(Map.delete(valid, field))
    end

    for field <- ["level", "sensitivity", "sanitizations", "confidence", "source", "chain"] do
      candidate = Map.update!(valid, "taint", &Map.delete(&1, field))
      assert {:error, _reason} = TaintEnvelope.decode_persisted(candidate)
    end
  end

  test "improper and overlong persisted chains fail closed in decode and resolve" do
    assert {:ok, envelope} = TaintEnvelope.new(payload(), taint())
    assert {:ok, valid} = TaintEnvelope.to_map(envelope)

    candidates = [
      put_in(valid, ["taint", "chain"], ["x" | :improper_tail]),
      put_in(valid, ["taint", "chain"], List.duplicate("x", 100_000))
    ]

    for candidate <- candidates do
      assert {:error, _reason} = TaintEnvelope.decode_persisted(candidate)

      assert {:ok, invalid, :invalid_durable_provenance} =
               TaintEnvelope.resolve(candidate, payload())

      assert invalid == Taint.invalid_durable_provenance()
    end
  end

  test "missing and invalid provenance resolve to exact conservative labels with status" do
    assert {:ok, envelope} = TaintEnvelope.new(payload(), taint())
    assert {:ok, persisted} = TaintEnvelope.to_map(envelope)
    assert {:ok, verified, :verified} = TaintEnvelope.resolve(persisted, payload())
    assert verified == envelope.taint

    assert {:ok, mismatch, :invalid_durable_provenance} =
             TaintEnvelope.resolve(persisted, Map.put(payload(), "a", "changed"))

    assert mismatch == Taint.invalid_durable_provenance()

    assert {:ok, missing, :legacy_unlabeled} = TaintEnvelope.resolve(:missing, payload())

    assert missing == %Taint{
             level: :untrusted,
             sensitivity: :restricted,
             sanitizations: 0,
             confidence: :unverified,
             source: "legacy_unlabeled",
             chain: []
           }

    assert {:ok, invalid, :invalid_durable_provenance} =
             TaintEnvelope.resolve(nil, payload())

    assert invalid == Taint.invalid_durable_provenance()

    assert {:ok, invalid, :invalid_durable_provenance} =
             TaintEnvelope.resolve(%{"not" => "an envelope"}, payload())

    assert invalid == Taint.invalid_durable_provenance()
  end

  test "normalizes JSON number equivalents and enforces the exact integer boundary" do
    assert {:ok, one} = TaintEnvelope.canonical_json(%{"n" => 1})
    assert {:ok, one_float} = TaintEnvelope.canonical_json(%{"n" => 1.0})
    assert {:ok, exponent} = TaintEnvelope.canonical_json(%{"n" => 1.0e3})
    assert {:ok, fractional} = TaintEnvelope.canonical_json(%{"n" => 1.5})
    nested_float = %{"outer" => [%{"n" => 1.5}, 1.5]}
    assert {:ok, nested_json} = TaintEnvelope.canonical_json(nested_float)

    assert {:ok, nested_again} =
             TaintEnvelope.canonical_json(Jason.decode!(nested_json))

    assert nested_again == nested_json
    assert {:ok, zero} = TaintEnvelope.canonical_json(%{"n" => -0.0})
    assert one == one_float
    assert exponent == ~s({"n":1000})
    assert fractional == ~s({"n":1.5})
    assert zero == ~s({"n":0})

    boundary = TaintEnvelope.limits().max_integer
    assert {:ok, _} = TaintEnvelope.canonical_json(%{"n" => boundary})

    assert {:error, :payload_number_limit} =
             TaintEnvelope.canonical_json(%{"n" => boundary + 1})

    assert {:ok, boundary_float} = TaintEnvelope.canonical_json(%{"n" => boundary * 1.0})
    assert boundary_float == TaintEnvelope.canonical_json(%{"n" => boundary}) |> elem(1)

    assert {:ok, decoded_json} = TaintEnvelope.canonical_json(Jason.decode!(one_float))
    assert decoded_json == one

    task = Task.async(fn -> TaintEnvelope.canonical_json(nested_float) end)
    assert {:ok, ^nested_json} = Task.await(task, 1_000)
  end

  test "rejects payloads beyond depth and non-finite numbers" do
    nested =
      Enum.reduce(1..(TaintEnvelope.limits().max_depth + 1), nil, fn _, value ->
        %{"n" => value}
      end)

    assert {:error, :payload_depth_exceeded} = TaintEnvelope.canonical_json(nested)

    assert {:error, :payload_number_limit} = TaintEnvelope.canonical_json(1.0e308)
  end

  test "rejects unsupported payload terms and explicit resource ceilings" do
    assert {:error, :unsupported_payload} = TaintEnvelope.canonical_json(self())
    assert {:error, :improper_payload} = TaintEnvelope.canonical_json([:ok | :tail])
    assert {:error, :invalid_payload_string} = TaintEnvelope.canonical_json(<<255>>)

    assert {:error, :payload_array_limit} =
             TaintEnvelope.canonical_json(
               List.duplicate(nil, TaintEnvelope.limits().max_array_items + 1)
             )

    assert {:error, :payload_string_limit} =
             TaintEnvelope.canonical_json(
               String.duplicate("x", TaintEnvelope.limits().max_string_bytes + 1)
             )

    assert {:error, :payload_byte_limit} =
             TaintEnvelope.canonical_json(List.duplicate(String.duplicate("x", 65_536), 17))
  end

  test "round-trips the persisted envelope map through JSON" do
    assert {:ok, envelope} = TaintEnvelope.new(payload(), taint())
    assert {:ok, persisted} = TaintEnvelope.to_map(envelope)
    round_tripped = persisted |> Jason.encode!() |> Jason.decode!()
    assert round_tripped == persisted
    assert {:ok, ^envelope} = TaintEnvelope.decode_persisted(round_tripped)
  end

  test "to_map is total for forged envelope structs" do
    assert {:ok, envelope} = TaintEnvelope.new(payload(), taint())
    forged = %{envelope | payload_sha256: <<255>>}
    assert {:error, :invalid_envelope} = TaintEnvelope.to_map(forged)
  end
end
