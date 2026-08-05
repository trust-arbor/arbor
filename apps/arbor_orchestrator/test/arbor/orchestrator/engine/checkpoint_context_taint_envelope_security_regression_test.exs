defmodule Arbor.Orchestrator.Engine.CheckpointContextTaintEnvelopeSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Orchestrator.Engine.{Checkpoint, Context}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "checkpoint_taint_envelope_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "security regression: exact context taint envelope round-trips against final value", %{
    root: root
  } do
    value = %{"nested" => %{answer: 42, state: :ready}}
    label = label()

    context =
      Context.new(
        %{
          "bound" => value,
          "__adapted_graph__" => self(),
          "__completed_nodes__" => ["start"]
        },
        taint: %{
          "bound" => label,
          "__adapted_graph__" => label,
          "__completed_nodes__" => label
        }
      )

    checkpoint = checkpoint(context, "run_exact_roundtrip")
    {path, payload} = write_and_decode(checkpoint, root)

    assert payload["context_values"] == %{
             "bound" => %{"nested" => %{"answer" => 42, "state" => "ready"}}
           }

    assert Map.keys(payload["context_taint"]) == ["bound"]
    envelope = payload["context_taint"]["bound"]

    assert Enum.sort(Map.keys(envelope)) ==
             ~w(payload_encoding payload_sha256 taint version)

    assert {:ok, %TaintEnvelope{taint: ^label}} =
             TaintEnvelope.verify(envelope, payload["context_values"]["bound"])

    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_taint == %{"bound" => label}
    assert %Taint{} = loaded.context_taint["bound"]
  end

  test "context taint envelope serialization is deterministic", %{root: root} do
    checkpoint = labelled_checkpoint(%{"b" => [2, 1], "a" => %{z: :ready}})
    first_root = Path.join(root, "first")
    second_root = Path.join(root, "second")

    assert :ok = Checkpoint.write(checkpoint, first_root, store: nil)
    assert :ok = Checkpoint.write(checkpoint, second_root, store: nil)

    assert File.read!(Path.join(first_root, "checkpoint.json")) ==
             File.read!(Path.join(second_root, "checkpoint.json"))
  end

  test "security regression: payload tampering with unchanged label fails closed", %{root: root} do
    checkpoint = labelled_checkpoint("approved")
    {path, payload} = write_and_decode(checkpoint, root)

    tampered = put_in(payload, ["context_values", "bound"], "attacker replacement")
    rewrite_payload(path, tampered)

    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)
  end

  test "security regression: unknown context taint envelope version rejects checkpoint", %{
    root: root
  } do
    {path, payload} = write_and_decode(labelled_checkpoint("value"), root)
    tampered = put_in(payload, ["context_taint", "bound", "version"], 2)
    rewrite_payload(path, tampered)

    assert {:error, :unsupported_version} = Checkpoint.load(path, store: nil)
  end

  test "security regression: malformed nested taint rejects checkpoint", %{root: root} do
    {path, payload} = write_and_decode(labelled_checkpoint("value"), root)
    tampered = put_in(payload, ["context_taint", "bound", "taint", "level"], "unknown")
    rewrite_payload(path, tampered)

    assert {:error, :invalid_taint} = Checkpoint.load(path, store: nil)
  end

  test "security regression: orphan context label rejects checkpoint", %{root: root} do
    {path, payload} = write_and_decode(labelled_checkpoint("value"), root)
    envelope = payload["context_taint"]["bound"]
    tampered = put_in(payload, ["context_taint", "orphan"], envelope)
    rewrite_payload(path, tampered)

    assert {:error, :orphan_context_taint} = Checkpoint.load(path, store: nil)
  end

  test "security regression: partial current envelope cannot enter legacy decoder", %{root: root} do
    {path, payload} = write_and_decode(labelled_checkpoint("value"), root)

    partial = Map.delete(payload["context_taint"]["bound"], "payload_sha256")
    tampered = put_in(payload, ["context_taint", "bound"], partial)
    rewrite_payload(path, tampered)

    assert {:error, :invalid_envelope_shape} = Checkpoint.load(path, store: nil)
  end

  test "exact legacy label migrates conservatively and rewrites only current envelope", %{
    root: root
  } do
    legacy = %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 0xFF,
      confidence: :verified,
      source: "legacy_source",
      chain: ["legacy_origin"]
    }

    {path, payload} = write_and_decode(labelled_checkpoint("legacy value"), root)

    legacy_payload =
      put_in(payload, ["context_taint", "bound"], Arbor.Signals.Taint.to_persistable(legacy))

    rewrite_payload(path, legacy_payload)

    assert {:ok, expected} = Taint.join(TaintEnvelope.missing_fallback(), legacy)
    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_taint == %{"bound" => expected}
    assert expected.level == :untrusted
    assert expected.sensitivity == :restricted
    assert expected.sanitizations == 0
    assert expected.confidence == :unverified

    migrated_root = Path.join(root, "migrated")
    {_migrated_path, migrated_payload} = write_and_decode(loaded, migrated_root)
    migrated = migrated_payload["context_taint"]["bound"]

    assert Enum.sort(Map.keys(migrated)) ==
             ~w(payload_encoding payload_sha256 taint version)

    refute Map.has_key?(migrated, "taint_level")

    assert {:ok, %TaintEnvelope{taint: ^expected}} =
             TaintEnvelope.verify(migrated, migrated_payload["context_values"]["bound"])
  end

  test "malformed and orphan in-memory labels fail before creating a file", %{root: root} do
    malformed =
      labelled_checkpoint("value")
      |> Map.put(:context_taint, %{"bound" => :untrusted})

    malformed_root = Path.join(root, "malformed")

    assert {:error, :invalid_context_taint} =
             Checkpoint.write(malformed, malformed_root, store: nil)

    refute File.exists?(Path.join(malformed_root, "checkpoint.json"))

    orphan =
      labelled_checkpoint("value")
      |> Map.put(:context_taint, %{"missing" => label()})

    orphan_root = Path.join(root, "orphan")

    assert {:error, :orphan_context_taint} =
             Checkpoint.write(orphan, orphan_root, store: nil)

    refute File.exists?(Path.join(orphan_root, "checkpoint.json"))
  end

  test "malformed context key fails closed without exposing its value", %{root: root} do
    checkpoint =
      labelled_checkpoint("value")
      |> Map.put(:context_values, %{42 => "must-not-appear"})
      |> Map.put(:context_taint, %{42 => label()})

    assert {:error, :invalid_context_key} = Checkpoint.write(checkpoint, root, store: nil)
    refute File.exists?(Path.join(root, "checkpoint.json"))
  end

  defp labelled_checkpoint(value) do
    Context.new(%{"bound" => value}, taint: %{"bound" => label()})
    |> checkpoint("run_context_taint_envelope")
  end

  defp checkpoint(%Context{} = context, run_id) do
    Checkpoint.from_state("node", ["start"], %{}, context, %{},
      run_id: run_id,
      graph_hash: "graph_hash"
    )
  end

  defp label do
    %Taint{
      level: :untrusted,
      sensitivity: :confidential,
      sanitizations: 0b101,
      confidence: :plausible,
      source: "voice_ingress",
      chain: ["authenticated_message"]
    }
  end

  defp write_and_decode(%Checkpoint{} = checkpoint, root) do
    assert :ok = Checkpoint.write(checkpoint, root, store: nil)
    path = Path.join(root, "checkpoint.json")
    {path, path |> File.read!() |> Jason.decode!()}
  end

  defp rewrite_payload(path, payload) do
    File.write!(path, Jason.encode!(payload, pretty: true))
  end
end
