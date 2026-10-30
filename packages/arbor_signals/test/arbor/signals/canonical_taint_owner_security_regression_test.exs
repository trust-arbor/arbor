defmodule Arbor.Signals.CanonicalTaintOwnerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Signals.Config
  alias Arbor.Signals.Contracts.Taint, as: LegacyTaint
  alias Arbor.Signals.Contracts.TaintEnvelope, as: LegacyEnvelope
  alias Arbor.Signals.Taint, as: SignalsTaint

  @moduletag :fast

  @fixture Path.expand("../../fixtures/taint_owner_v1.json", __DIR__)
  @external_resource @fixture

  setup do
    keys = [:taint_module, :taint_envelope_module]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_signals, &1)})
    Enum.each(keys, &Application.delete_env(:arbor_signals, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_signals, key, value)
        {key, :error} -> Application.delete_env(:arbor_signals, key)
      end)
    end)

    :ok
  end

  test "security regression: default Signals joins canonical Kernel taints monotonically" do
    left = taint(%{level: :derived, sensitivity: :confidential, sanitizations: 3})

    right =
      taint(%{
        level: :untrusted,
        sensitivity: :restricted,
        sanitizations: 1,
        confidence: :plausible,
        source: "source_b"
      })

    joined = SignalsTaint.propagate_taint([left, right])

    assert %Taint{} = joined

    assert Map.from_struct(joined) == %{
             level: :untrusted,
             sensitivity: :restricted,
             sanitizations: 1,
             confidence: :plausible,
             source: "source_a",
             chain: ["source_b"]
           }
  end

  test "durable v1 envelopes and canonical payload bytes retain the pre-consolidation format" do
    golden = @fixture |> File.read!() |> Jason.decode!()
    {:ok, label} = Taint.new(golden["envelope"]["taint"])

    assert {:ok, envelope} = SignalsTaint.bind_durable_provenance(golden["payload"], label)
    assert envelope == golden["envelope"]
    assert Jason.encode!(envelope) == golden["envelope_json"]
    assert {:ok, canonical_payload} = TaintEnvelope.canonical_json(golden["payload"])
    assert canonical_payload == golden["canonical_payload"]

    assert {:ok, %TaintEnvelope{taint: ^label}} =
             SignalsTaint.verify_durable_provenance(envelope, golden["payload"])

    assert {:ok, %TaintEnvelope{taint: ^label}} =
             TaintEnvelope.verify(envelope, golden["payload"])

    assert {:error, :payload_mismatch} =
             SignalsTaint.verify_durable_provenance(envelope, %{"tampered" => true})
  end

  test "security regression: invalid, foreign and legacy struct-tagged inputs stay absorbing" do
    valid = taint(%{})
    invalid = Taint.invalid_durable_provenance()

    for bad <- [
          invalid,
          %{valid | confidence: :unknown},
          Map.put(Map.from_struct(valid), :__struct__, LegacyTaint),
          Map.put(Map.from_struct(valid), :__struct__, __MODULE__),
          %{}
        ] do
      assert SignalsTaint.propagate_taint([valid, bad]) == invalid
      assert SignalsTaint.propagate_taint([bad, valid]) == invalid
    end
  end

  test "legacy builtin selectors and function names resolve to the single canonical owner" do
    Application.put_env(:arbor_signals, :taint_module, LegacyTaint)
    Application.put_env(:arbor_signals, :taint_envelope_module, LegacyEnvelope)

    assert Config.taint_module() == Taint
    assert Config.taint_envelope_module() == TaintEnvelope
    assert %Taint{level: :untrusted} = SignalsTaint.from_level(:untrusted)
    assert %Taint{level: :derived, sanitizations: 0} = SignalsTaint.for_llm_output(taint(%{}))

    assert {:ok, %Taint{} = label} =
             LegacyTaint.new(Map.from_struct(taint(%{level: :untrusted})))

    assert {:ok, %TaintEnvelope{taint: ^label}} = LegacyEnvelope.new(%{}, label)
    refute function_exported?(LegacyTaint, :__struct__, 0)
    refute function_exported?(LegacyEnvelope, :__struct__, 0)
  end

  test "trusted host provider selectors remain configurable" do
    Application.put_env(:arbor_signals, :taint_module, __MODULE__)
    Application.put_env(:arbor_signals, :taint_envelope_module, __MODULE__)
    assert Config.taint_module() == __MODULE__
    assert Config.taint_envelope_module() == __MODULE__
  end

  test "legacy labels decode canonically while exact-term hashes are never rewritten" do
    label = taint(%{})
    legacy_term = Map.put(Map.from_struct(label), :__struct__, LegacyTaint)

    for input <- [label, legacy_term] do
      expected =
        :crypto.hash(:sha256, :erlang.term_to_binary(input)) |> Base.encode16(case: :lower)

      assert SignalsTaint.data_hash(input) == expected
      assert :ok = SignalsTaint.verify_data_hash(input, expected)
    end

    persisted = SignalsTaint.to_persistable(label, data_hash: "legacy-opaque-hash")
    assert persisted["taint_data_hash"] == "legacy-opaque-hash"
    assert SignalsTaint.from_persistable(persisted) == label
  end

  defp taint(overrides) do
    attrs = %{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 3,
      confidence: :verified,
      source: "source_a",
      chain: []
    }

    {:ok, label} = Taint.new(Map.merge(attrs, overrides))
    label
  end
end
