defmodule Arbor.Memory.MemoryStoreTaintTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{Record}
  alias Arbor.Contracts.Security.{Taint, TaintedValue}
  alias Arbor.Memory.MemoryStore
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Signals.Taint, as: TaintModule

  @moduletag :fast
  @store_name :arbor_memory_durable

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
    :ok
  end

  describe "durable writes" do
    test "stores a JSON-safe payload-bound envelope from the actual data" do
      data = %{"secret" => "value"}
      taint = %Taint{level: :untrusted, sensitivity: :confidential, source: "test"}

      assert :ok =
               MemoryStore.persist("write", "valid", data,
                 taint: taint,
                 data: %{"caller_selected" => "not-bound"}
               )

      assert {:ok, %Record{data: ^data, metadata: %{"taint" => envelope}}} =
               BufferedStore.get("write:valid", name: @store_name)

      assert is_integer(envelope["version"])
      assert is_binary(envelope["payload_sha256"])
      assert is_map(envelope["taint"])
      assert {:ok, _json} = Jason.encode(envelope)

      assert {:ok, value, :verified} = MemoryStore.load_tainted_with_status("write", "valid")
      assert value.value == data
      assert value.taint.level == :untrusted
      assert value.taint.sensitivity == :confidential
    end

    test "writes empty metadata when no taint is supplied" do
      assert :ok = MemoryStore.persist("write", "plain", %{"value" => "plain"})

      assert {:ok, %Record{metadata: %{}}} =
               BufferedStore.get("write:plain", name: @store_name)
    end

    test "rejects malformed taint without inserting the record or leaking data" do
      data = %{"secret" => "do-not-leak"}
      malformed = %Taint{level: :not_a_level}

      error = MemoryStore.persist("write", "malformed", data, taint: malformed)

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} = error
      refute inspect(error) =~ "do-not-leak"
      assert {:error, :not_found} = BufferedStore.get("write:malformed", name: @store_name)
    end

    test "rejects an oversized payload before inserting the record" do
      data = %{"payload" => String.duplicate("x", 65_537)}
      taint = %Taint{level: :untrusted}

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} =
               MemoryStore.persist("write", "oversized", data, taint: taint)

      assert {:error, :not_found} = BufferedStore.get("write:oversized", name: @store_name)
    end

    test "validates supplied labels before honoring unavailable-store degradation" do
      stop_supervised!(BufferedStore)
      assert Process.whereis(@store_name) == nil
      malformed = %Taint{level: :not_a_level}

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} =
               MemoryStore.persist("write", "unavailable-invalid", %{"secret" => "value"},
                 taint: malformed
               )

      assert :ok = MemoryStore.persist("write", "unavailable-plain", %{"value" => "plain"})

      assert :ok =
               MemoryStore.persist_async("write", "unavailable-valid", %{"value" => "valid"},
                 taint: %Taint{level: :derived}
               )
    end

    test "rejects non-keyword options without raising" do
      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.persist("write", "bad-options", %{}, %{})

      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.persist_async("write", "bad-options", %{}, [:taint])

      improper = [{:taint, %Taint{level: :derived}} | :tail]

      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.persist("write", "improper-options", %{}, improper)
    end

    test "persist_async validates labeled input before spawning" do
      data = %{"secret" => "async-do-not-leak"}
      malformed = %Taint{level: :not_a_level}

      error = MemoryStore.persist_async("async", "malformed", data, taint: malformed)

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} = error
      refute inspect(error) =~ "async-do-not-leak"
      assert {:error, :not_found} = BufferedStore.get("async:malformed", name: @store_name)
    end

    test "persist_async keeps valid writes fire-and-forget" do
      assert :ok =
               MemoryStore.persist_async("async", "valid", %{"value" => "written"},
                 taint: %Taint{level: :derived}
               )

      assert eventually(fn ->
               match?({:ok, %Record{}}, BufferedStore.get("async:valid", name: @store_name))
             end)
    end
  end

  describe "tainted reads" do
    test "missing metadata is untrusted, restricted, and unverified" do
      put_raw("read:missing", %{"value" => "legacy"}, %{})

      assert {:ok, value, :legacy_unlabeled} =
               MemoryStore.load_tainted_with_status("read", "missing")

      assert value.taint.level == :untrusted
      assert value.taint.sensitivity == :restricted
      assert value.taint.confidence == :unverified
      assert value.taint.source == "legacy_unlabeled"

      assert {:ok, compatibility_value} = MemoryStore.load_tainted("read", "missing")
      assert compatibility_value.taint.level == :untrusted
    end

    test "malformed, old, unknown-version, atom-key, and ambiguous metadata are invalid" do
      data = %{"value" => "tamper"}
      {:ok, envelope} = TaintModule.bind_durable_provenance(data, %Taint{level: :derived})

      cases = [
        {"malformed", %{"taint" => %{"version" => 1}}},
        {"old", %{"taint" => %{"taint_level" => "trusted"}}},
        {"atom_old", %{taint_level: "trusted"}},
        {"unknown", %{"taint" => Map.put(envelope, "version", 99)}},
        {"atom", %{taint: envelope}},
        {"ambiguous", Map.merge(%{taint: envelope}, %{"taint" => envelope})},
        {"valid_plus_legacy", %{"taint" => envelope, "taint_level" => "trusted"}},
        {"payload_mismatch", %{"taint" => envelope}}
      ]

      Enum.each(cases, fn {key, metadata} ->
        tampered_data =
          if key == "payload_mismatch", do: %{"value" => "changed"}, else: data

        put_raw("read:#{key}", tampered_data, metadata)

        assert {:ok, value, :invalid_durable_provenance} =
                 MemoryStore.load_tainted_with_status("read", key)

        assert value.taint.level == :hostile
        assert value.taint.sensitivity == :restricted
        assert value.taint.confidence == :unverified
        assert value.taint.source == "invalid_durable_provenance"
      end)
    end

    test "non-map metadata is invalid rather than missing" do
      put_raw("read:non_map", %{"value" => "legacy"}, :taint)

      assert {:ok, value, :invalid_durable_provenance} =
               MemoryStore.load_tainted_with_status("read", "non_map")

      assert value.taint.level == :hostile
    end

    test "security regression: missing metadata never emerges trusted or control-eligible" do
      put_raw("security:missing", %{"command" => "do-not-run"}, %{})

      assert {:ok, value} = MemoryStore.load_tainted("security", "missing")
      refute TaintedValue.level?(value, :trusted)
      assert value.taint.level == :untrusted
      assert value.taint.sensitivity == :restricted
      assert value.taint.confidence == :unverified
    end

    test "collections retain each item's taint and status" do
      verified_data = %{"value" => "verified"}

      {:ok, envelope} =
        TaintModule.bind_durable_provenance(verified_data, %Taint{level: :derived})

      put_raw("collection:verified", verified_data, %{"taint" => envelope})
      put_raw("collection:missing", %{"value" => "missing"}, %{})
      put_raw("collection:invalid", %{"value" => "invalid"}, %{taint: envelope})

      assert {:ok, entries} = MemoryStore.load_all_tainted("collection")
      assert Enum.map(entries, &elem(&1, 0)) == ["invalid", "missing", "verified"]

      statuses =
        Map.new(entries, fn {key, value, status} -> {key, {value.taint.level, status}} end)

      assert statuses["verified"] == {:derived, :verified}
      assert statuses["missing"] == {:untrusted, :legacy_unlabeled}
      assert statuses["invalid"] == {:hostile, :invalid_durable_provenance}

      assert {:ok, [{"verified", value, :verified}]} =
               MemoryStore.load_by_prefix_tainted("collection", "verified")

      assert value.taint.level == :derived
    end
  end

  describe "legacy taint compatibility helpers" do
    test "preserves all fields through the versionless compatibility format" do
      original = %Taint{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0b00010011,
        confidence: :plausible,
        source: "external_api",
        chain: ["step1", "step2"]
      }

      persistable = TaintModule.to_persistable(original)
      restored = TaintModule.from_persistable(persistable)

      assert restored.level == original.level
      assert restored.sensitivity == original.sensitivity
      assert restored.sanitizations == original.sanitizations
      assert restored.confidence == original.confidence
      assert restored.source == original.source
      assert restored.chain == original.chain
    end

    test "persistable format uses string keys and survives JSON" do
      original = %Taint{level: :derived, sensitivity: :internal, confidence: :verified}
      persistable = TaintModule.to_persistable(original)

      assert is_binary(Map.keys(persistable) |> hd())
      assert persistable["taint_level"] == "derived"

      restored =
        persistable |> Jason.encode!() |> Jason.decode!() |> TaintModule.from_persistable()

      assert restored.level == original.level
      assert restored.sensitivity == original.sensitivity
      assert restored.confidence == original.confidence
    end
  end

  describe "embedding provenance" do
    test "invalid embedding taint returns a bounded error before spawning" do
      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} =
               MemoryStore.embed_async("embedding", "invalid", "sensitive-content",
                 agent_id: "agent_test",
                 taint: %Taint{level: :not_a_level}
               )
    end

    test "invalid embedding type returns a bounded error without raising" do
      assert {:error, {:memory_store, :invalid_request, :invalid_type}} =
               MemoryStore.embed_async("embedding", "invalid-type", "content",
                 agent_id: "agent_test",
                 type: %{}
               )

      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.embed_async("embedding", "bad-options", "content", %{type: :thought})
    end
  end

  defp put_raw(key, data, metadata) do
    record = Record.new(key, data, id: "memory:#{key}", metadata: metadata)
    assert :ok = BufferedStore.put(key, record, name: @store_name)
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
