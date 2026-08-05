defmodule Arbor.Orchestrator.Engine.CheckpointContextTaintEnvelopeSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Orchestrator.DurableJson
  alias Arbor.Orchestrator.Engine.{Checkpoint, Context}

  defmodule SpyStore do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)
      %{id: name, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{data: %{}, events: []}, name: name)
    end

    def durability_class(opts) do
      opts |> Keyword.fetch!(:name) |> GenServer.call(:durability_class)
    end

    def put(key, value, opts) do
      GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
    end

    def get(key, opts) do
      GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    end

    def delete(key, opts) do
      GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    end

    def list(opts) do
      opts |> Keyword.fetch!(:name) |> GenServer.call(:list)
    end

    def events(name), do: GenServer.call(name, :events)
    def fetch(name, key), do: GenServer.call(name, {:fetch, key})
    def replace(name, key, value), do: GenServer.call(name, {:replace, key, value})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:durability_class, _from, state) do
      {:reply, :process_lifetime, record_event(state, :durability_class)}
    end

    def handle_call({:put, key, value}, _from, state) do
      state = state |> put_in([:data, key], value) |> record_event({:put, key})
      {:reply, :ok, state}
    end

    def handle_call({:get, key}, _from, state) do
      state = record_event(state, {:get, key})

      case Map.fetch(state.data, key) do
        {:ok, value} -> {:reply, {:ok, value}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:delete, key}, _from, state) do
      state = state |> update_in([:data], &Map.delete(&1, key)) |> record_event({:delete, key})
      {:reply, :ok, state}
    end

    def handle_call(:list, _from, state) do
      {:reply, {:ok, Map.keys(state.data)}, record_event(state, :list)}
    end

    def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

    def handle_call({:fetch, key}, _from, state) do
      {:reply, Map.fetch!(state.data, key), state}
    end

    def handle_call({:replace, key, value}, _from, state) do
      {:reply, :ok, put_in(state, [:data, key], value)}
    end

    defp record_event(state, event), do: update_in(state.events, &[event | &1])
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "checkpoint_taint_envelope_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"checkpoint_taint_envelope_store_#{suffix}"
    start_supervised!({SpyStore, name: store_name})

    %{root: root, store_name: store_name}
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

    binding =
      expected_context_binding("bound", {:present, payload["context_values"]["bound"]})

    assert {:ok, %TaintEnvelope{taint: ^label}} =
             TaintEnvelope.verify(envelope, binding)

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

  test "security regression: current write envelopes an unlabeled context value", %{root: root} do
    checkpoint =
      Context.new(%{"unlabelled" => %{"state" => :ready}})
      |> checkpoint("run_current_missing_provenance")

    {path, payload} = write_and_decode(checkpoint, root)
    value = payload["context_values"]["unlabelled"]
    envelope = payload["context_taint"]["unlabelled"]
    fallback = TaintEnvelope.missing_fallback()
    binding = expected_context_binding("unlabelled", {:present, value})

    assert {:ok, %TaintEnvelope{taint: ^fallback}} = TaintEnvelope.verify(envelope, binding)
    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_taint == %{"unlabelled" => fallback}
  end

  test "security regression: payload tampering with unchanged label fails closed", %{root: root} do
    checkpoint = labelled_checkpoint("approved")
    {path, payload} = write_and_decode(checkpoint, root)

    tampered = put_in(payload, ["context_values", "bound"], "attacker replacement")
    rewrite_payload(path, tampered)

    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)
  end

  test "security regression: equal-value context envelopes cannot be swapped between keys", %{
    root: root
  } do
    left_label = label()
    right_label = %{label() | source: "other_source"}

    context =
      Context.new(%{"left" => "same", "right" => "same"},
        taint: %{"left" => left_label, "right" => right_label}
      )

    {path, payload} =
      context
      |> checkpoint("run_equal_value_swap")
      |> write_and_decode(root)

    left_envelope = payload["context_taint"]["left"]
    right_envelope = payload["context_taint"]["right"]

    tampered =
      payload
      |> put_in(["context_taint", "left"], right_envelope)
      |> put_in(["context_taint", "right"], left_envelope)

    rewrite_payload(path, tampered)

    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)
  end

  test "security regression: large context key round-trips and key tampering fails closed", %{
    root: root
  } do
    key = String.duplicate("K", TaintEnvelope.limits().max_string_bytes + 1)
    changed_key = "Y" <> binary_part(key, 1, byte_size(key) - 1)

    context = Context.new(%{key => "value"}, taint: %{key => label()})

    {path, payload} =
      context
      |> checkpoint("run_large_context_key")
      |> write_and_decode(root)

    assert payload["context_values"][key] == "value"
    envelope = payload["context_taint"][key]
    binding = expected_context_binding(key, {:present, "value"})
    assert {:ok, %TaintEnvelope{taint: expected}} = TaintEnvelope.verify(envelope, binding)
    assert expected == label()

    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_values == %{key => "value"}
    assert loaded.context_taint == %{key => label()}

    tampered =
      payload
      |> update_in(["context_values"], fn values ->
        values |> Map.delete(key) |> Map.put(changed_key, "value")
      end)
      |> update_in(["context_taint"], fn taint ->
        taint |> Map.delete(key) |> Map.put(changed_key, envelope)
      end)

    rewrite_payload(path, tampered)
    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)
  end

  test "security regression: unpublished raw-value envelope is not a current format", %{
    root: root
  } do
    {path, payload} = write_and_decode(labelled_checkpoint("value"), root)
    value = payload["context_values"]["bound"]
    assert {:ok, raw_envelope} = TaintEnvelope.new(value, label())
    assert {:ok, raw_persisted} = TaintEnvelope.to_map(raw_envelope)

    payload
    |> put_in(["context_taint", "bound"], raw_persisted)
    |> then(&rewrite_payload(path, &1))

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

  test "security regression: forged ambient label with another key's envelope fails closed", %{
    root: root
  } do
    {path, payload} = write_and_decode(labelled_checkpoint("value"), root)
    envelope = payload["context_taint"]["bound"]
    tampered = put_in(payload, ["context_taint", "orphan"], envelope)
    rewrite_payload(path, tampered)

    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)
  end

  test "security regression: current ambient provenance binds absence without value collision", %{
    root: root
  } do
    former_sentinel = %{"kind" => "arbor_context_absent_v1", "key" => "present"}
    ambient_label = %{label() | source: "ambient_floor"}

    context =
      Context.new(%{"present" => former_sentinel},
        taint: %{"present" => label(), "ambient" => ambient_label}
      )

    {path, payload} =
      context
      |> checkpoint("run_current_ambient")
      |> write_and_decode(root)

    present_envelope = payload["context_taint"]["present"]
    ambient_envelope = payload["context_taint"]["ambient"]

    present_binding =
      expected_context_binding("present", {:present, payload["context_values"]["present"]})

    ambient_binding = expected_context_binding("ambient", :absent)

    assert {:ok, %TaintEnvelope{taint: present_taint}} =
             TaintEnvelope.verify(present_envelope, present_binding)

    assert {:ok, %TaintEnvelope{taint: ^ambient_label}} =
             TaintEnvelope.verify(ambient_envelope, ambient_binding)

    assert present_taint == label()
    refute present_envelope["payload_sha256"] == ambient_envelope["payload_sha256"]

    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_values["present"] == former_sentinel
    assert loaded.context_taint["ambient"] == ambient_label

    removed_value = update_in(payload, ["context_values"], &Map.delete(&1, "present"))
    rewrite_payload(path, removed_value)
    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)

    added_value = put_in(payload, ["context_values", "ambient"], former_sentinel)
    rewrite_payload(path, added_value)
    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)
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

    binding =
      expected_context_binding(
        "bound",
        {:present, migrated_payload["context_values"]["bound"]}
      )

    assert {:ok, %TaintEnvelope{taint: ^expected}} =
             TaintEnvelope.verify(migrated, binding)
  end

  test "security regression: legacy context value absent from taint map gets missing fallback", %{
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

    context =
      Context.new(
        %{"legacy_labelled" => "labelled", "legacy_missing" => "missing"},
        taint: %{"legacy_labelled" => legacy}
      )

    {path, payload} =
      context
      |> checkpoint("run_legacy_missing_provenance")
      |> write_and_decode(root)

    legacy_context_taint =
      payload["context_taint"]
      |> Map.put("legacy_labelled", Arbor.Signals.Taint.to_persistable(legacy))
      |> Map.delete("legacy_missing")

    rewrite_payload(path, Map.put(payload, "context_taint", legacy_context_taint))

    assert {:ok, migrated_legacy} = Taint.join(TaintEnvelope.missing_fallback(), legacy)
    assert {:ok, loaded} = Checkpoint.load(path, store: nil)

    assert loaded.context_taint == %{
             "legacy_labelled" => migrated_legacy,
             "legacy_missing" => TaintEnvelope.missing_fallback()
           }
  end

  test "security regression: legacy ambient label migrates conservatively and binds absence", %{
    root: root
  } do
    legacy = %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 0xFF,
      confidence: :verified,
      source: "legacy_ambient",
      chain: ["legacy_origin"]
    }

    context = Context.new(%{"live" => "value"}, taint: %{"ambient" => legacy})

    {path, payload} =
      context
      |> checkpoint("run_legacy_ambient")
      |> write_and_decode(root)

    legacy_payload =
      put_in(
        payload,
        ["context_taint", "ambient"],
        Arbor.Signals.Taint.to_persistable(legacy)
      )

    rewrite_payload(path, legacy_payload)

    assert {:ok, expected} = Taint.join(TaintEnvelope.missing_fallback(), legacy)
    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_values == %{"live" => "value"}
    assert loaded.context_taint["ambient"] == expected
    assert expected.level == :untrusted
    assert expected.sensitivity == :restricted
    assert expected.sanitizations == 0

    migrated_root = Path.join(root, "legacy_ambient_migrated")
    {migrated_path, migrated_payload} = write_and_decode(loaded, migrated_root)
    migrated_envelope = migrated_payload["context_taint"]["ambient"]
    ambient_binding = expected_context_binding("ambient", :absent)

    assert {:ok, %TaintEnvelope{taint: ^expected}} =
             TaintEnvelope.verify(migrated_envelope, ambient_binding)

    tampered = put_in(migrated_payload, ["context_values", "ambient"], "now present")
    rewrite_payload(migrated_path, tampered)
    assert {:error, :payload_mismatch} = Checkpoint.load(migrated_path, store: nil)
  end

  test "malformed in-memory label fails before creating a file", %{root: root} do
    malformed =
      labelled_checkpoint("value")
      |> Map.put(:context_taint, %{"bound" => :untrusted})

    malformed_root = Path.join(root, "malformed")

    assert {:error, :invalid_context_taint} =
             Checkpoint.write(malformed, malformed_root, store: nil)

    refute File.exists?(Path.join(malformed_root, "checkpoint.json"))
  end

  test "malformed context key fails closed without exposing its value", %{root: root} do
    checkpoint =
      labelled_checkpoint("value")
      |> Map.put(:context_values, %{42 => "must-not-appear"})
      |> Map.put(:context_taint, %{42 => label()})

    assert {:error, :invalid_context_key} = Checkpoint.write(checkpoint, root, store: nil)
    refute File.exists?(Path.join(root, "checkpoint.json"))
  end

  test "security regression: unencodable unlabeled value has zero persist or write effects", %{
    root: root,
    store_name: store_name
  } do
    checkpoint =
      Context.new(%{"unlabelled" => self()})
      |> checkpoint("run_unencodable_unlabelled")

    persist_root = Path.join(root, "persist_unencodable")

    assert {:error, :unsupported_payload} =
             Checkpoint.persist(checkpoint, persist_root, configured_store_opts(store_name))

    assert SpyStore.events(store_name) == []
    refute File.exists?(persist_root)

    write_root = Path.join(root, "write_unencodable")

    assert {:error, :unsupported_payload} =
             Checkpoint.write(checkpoint, write_root, configured_store_opts(store_name))

    assert SpyStore.events(store_name) == []
    refute File.exists?(write_root)
  end

  test "security regression: duplicate normalized value keys fail before persistence effects", %{
    root: root,
    store_name: store_name
  } do
    checkpoint =
      Context.new(%{"duplicate" => %{:same => 1, "same" => 2}})
      |> checkpoint("run_duplicate_normalized_value_keys")

    attempt_root = Path.join(root, "duplicate_normalized_value_keys")

    assert {:error, :duplicate_json_key} =
             Checkpoint.persist(checkpoint, attempt_root, configured_store_opts(store_name))

    assert SpyStore.events(store_name) == []
    refute File.exists?(attempt_root)
  end

  test "security regression: one megabyte value keeps conservative provenance and detects tamper",
       %{root: root} do
    value = String.duplicate("X", 1_000_000)

    checkpoint =
      Context.new(%{"blob" => value})
      |> checkpoint("run_large_context_value")

    {path, payload} = write_and_decode(checkpoint, root)
    assert payload["context_values"]["blob"] == value

    fallback = TaintEnvelope.missing_fallback()
    binding = expected_context_binding("blob", {:present, value})

    assert {:ok, %TaintEnvelope{taint: ^fallback}} =
             TaintEnvelope.verify(payload["context_taint"]["blob"], binding)

    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_values["blob"] == value
    assert loaded.context_taint["blob"] == fallback

    changed = "Y" <> binary_part(value, 1, byte_size(value) - 1)
    tampered = put_in(payload, ["context_values", "blob"], changed)
    rewrite_payload(path, tampered)

    assert {:error, :payload_mismatch} = Checkpoint.load(path, store: nil)
  end

  test "checkpoint descriptor accepts values beyond ordinary TaintEnvelope traversal limits", %{
    root: root
  } do
    large_array = Enum.to_list(1..300)
    large_object = Map.new(1..300, &{"key_#{&1}", &1})
    many_nodes = Enum.map(1..256, fn _ -> Enum.to_list(1..20) end)

    assert {:error, :payload_array_limit} = TaintEnvelope.new(large_array, label())
    assert {:error, :payload_object_limit} = TaintEnvelope.new(large_object, label())
    assert {:error, :payload_node_limit} = TaintEnvelope.new(many_nodes, label())

    values = %{
      "large_array" => large_array,
      "large_object" => large_object,
      "many_nodes" => many_nodes
    }

    checkpoint =
      Context.new(values)
      |> checkpoint("run_large_structured_context_values")

    {path, payload} = write_and_decode(checkpoint, root)
    assert payload["context_values"] == values
    assert {:ok, loaded} = Checkpoint.load(path, store: nil)
    assert loaded.context_values == values

    fallback = TaintEnvelope.missing_fallback()

    assert loaded.context_taint == %{
             "large_array" => fallback,
             "large_object" => fallback,
             "many_nodes" => fallback
           }
  end

  test "configured store persists the exact file projection and restores in-memory taint", %{
    root: root,
    store_name: store_name
  } do
    run_id = "run_configured_store_envelope"
    checkpoint = labelled_checkpoint(%{"nested" => %{state: :ready}})
    checkpoint = %{checkpoint | run_id: run_id}
    opts = configured_store_opts(store_name)

    assert {:ok, receipt} = Checkpoint.persist(checkpoint, root, opts)
    assert receipt.store == :ok
    assert receipt.file == :ok

    key = "checkpoint:#{run_id}"
    assert %PersistenceRecord{data: stored_payload} = SpyStore.fetch(store_name, key)
    file_payload = root |> Path.join("checkpoint.json") |> File.read!() |> Jason.decode!()

    assert stored_payload == file_payload

    assert stored_payload["context_values"]["bound"] == %{
             "nested" => %{"state" => "ready"}
           }

    binding =
      expected_context_binding(
        "bound",
        {:present, stored_payload["context_values"]["bound"]}
      )

    assert {:ok, %TaintEnvelope{taint: expected_taint}} =
             TaintEnvelope.verify(stored_payload["context_taint"]["bound"], binding)

    assert {:ok, loaded} =
             Checkpoint.load(Path.join(root, "checkpoint.json"),
               run_id: run_id,
               store: SpyStore,
               store_name: store_name
             )

    assert loaded.context_values == stored_payload["context_values"]
    assert loaded.context_taint == %{"bound" => expected_taint}
  end

  test "security regression: configured-store mixed envelope keys reject the checkpoint", %{
    root: root,
    store_name: store_name
  } do
    run_id = "run_mixed_envelope_keys"
    checkpoint = labelled_checkpoint("value") |> Map.put(:run_id, run_id)
    opts = configured_store_opts(store_name)
    assert {:ok, _receipt} = Checkpoint.persist(checkpoint, root, opts)

    key = "checkpoint:#{run_id}"
    record = SpyStore.fetch(store_name, key)
    envelope = record.data["context_taint"]["bound"]
    mixed = envelope |> Map.delete("version") |> Map.put(:version, envelope["version"])
    tampered_data = put_in(record.data, ["context_taint", "bound"], mixed)
    :ok = SpyStore.replace(store_name, key, %{record | data: tampered_data})

    assert {:error, :mixed_keys} =
             Checkpoint.load(Path.join(root, "checkpoint.json"),
               run_id: run_id,
               store: SpyStore,
               store_name: store_name
             )
  end

  test "HMAC covers the final configured-store envelope structure", %{
    root: root,
    store_name: store_name
  } do
    run_id = "run_hmac_envelope"
    secret = "checkpoint-hmac-secret"
    checkpoint = labelled_checkpoint("signed value") |> Map.put(:run_id, run_id)
    opts = configured_store_opts(store_name, hmac_secret: secret)

    assert {:ok, _receipt} = Checkpoint.persist(checkpoint, root, opts)

    assert {:ok, loaded} =
             Checkpoint.load(Path.join(root, "checkpoint.json"),
               run_id: run_id,
               store: SpyStore,
               store_name: store_name,
               hmac_secret: secret
             )

    assert loaded.context_taint == %{"bound" => label()}

    key = "checkpoint:#{run_id}"
    record = SpyStore.fetch(store_name, key)
    assert is_binary(record.data["__hmac"])

    tampered_data =
      put_in(record.data, ["context_values", "bound"], "attacker replacement")

    :ok = SpyStore.replace(store_name, key, %{record | data: tampered_data})

    assert {:error, :tampered} =
             Checkpoint.load(Path.join(root, "checkpoint.json"),
               run_id: run_id,
               store: SpyStore,
               store_name: store_name,
               hmac_secret: secret
             )
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

  defp expected_context_binding(key, :absent) do
    %{
      "kind" => "arbor_context_taint_binding",
      "version" => 1,
      "key" => expected_key_binding(key),
      "presence" => "absent"
    }
  end

  defp expected_context_binding(key, {:present, projected_value}) do
    assert {:ok, digest} = DurableJson.project_and_digest(projected_value)
    assert digest.projection == projected_value

    %{
      "kind" => "arbor_context_taint_binding",
      "version" => 1,
      "key" => expected_key_binding(key),
      "presence" => "present",
      "value_encoding" => digest.encoding,
      "value_digest" => digest.digest_algorithm,
      "value_sha256" => digest.sha256
    }
  end

  defp expected_key_binding(key) do
    %{
      "encoding" => "utf8_bytes_v1",
      "bytes" => byte_size(key),
      "sha256" => key |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    }
  end

  defp configured_store_opts(store_name, extra \\ []) do
    Keyword.merge([store: SpyStore, store_name: store_name], extra)
  end
end
