defmodule Arbor.Common.SafeAtomTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.SafeAtom

  @moduletag :fast

  describe "to_existing/1" do
    test "converts known atoms" do
      assert {:ok, :ok} = SafeAtom.to_existing("ok")
      assert {:ok, :error} = SafeAtom.to_existing("error")
      assert {:ok, true} = SafeAtom.to_existing("true")
      assert {:ok, false} = SafeAtom.to_existing("false")
    end

    test "returns error for unknown atoms" do
      assert {:error, {:unknown_atom, "definitely_not_a_real_atom_xyz123"}} =
               SafeAtom.to_existing("definitely_not_a_real_atom_xyz123")
    end

    test "passes through existing atoms" do
      assert {:ok, :already_an_atom} = SafeAtom.to_existing(:already_an_atom)
    end

    test "handles nil" do
      assert {:ok, nil} = SafeAtom.to_existing(nil)
    end
  end

  describe "to_existing!/1" do
    test "converts known atoms" do
      assert :ok = SafeAtom.to_existing!("ok")
      assert :error = SafeAtom.to_existing!("error")
    end

    test "raises for unknown atoms" do
      assert_raise ArgumentError, fn ->
        SafeAtom.to_existing!("definitely_not_a_real_atom_abc789")
      end
    end

    test "passes through existing atoms" do
      assert :test_atom = SafeAtom.to_existing!(:test_atom)
    end
  end

  describe "to_allowed/2" do
    test "allows atoms in the allowed list" do
      assert {:ok, :read} = SafeAtom.to_allowed("read", [:read, :write, :delete])
      assert {:ok, :write} = SafeAtom.to_allowed("write", [:read, :write, :delete])
    end

    test "rejects atoms not in allowed list" do
      assert {:error, {:not_allowed, :execute}} =
               SafeAtom.to_allowed("execute", [:read, :write])
    end

    test "rejects unknown strings" do
      assert {:error, {:not_allowed, "unknown_action_xyz"}} =
               SafeAtom.to_allowed("unknown_action_xyz", [:read, :write])
    end

    test "works with atom input" do
      assert {:ok, :read} = SafeAtom.to_allowed(:read, [:read, :write])
      assert {:error, {:not_allowed, :delete}} = SafeAtom.to_allowed(:delete, [:read, :write])
    end
  end

  describe "atomize_keys/2" do
    test "atomizes known keys" do
      input = %{"name" => "test", "id" => 123}
      assert %{name: "test", id: 123} = SafeAtom.atomize_keys(input, [:name, :id])
    end

    test "keeps unknown keys as strings" do
      input = %{"name" => "test", "unknown" => "value"}
      result = SafeAtom.atomize_keys(input, [:name, :id])

      assert %{"unknown" => "value", name: "test"} = result
    end

    test "handles already-atom keys" do
      input = %{"id" => 123, name: "test"}
      assert %{name: "test", id: 123} = SafeAtom.atomize_keys(input, [:name, :id])
    end

    test "handles empty map" do
      assert %{} = SafeAtom.atomize_keys(%{}, [:name, :id])
    end

    test "handles empty known_keys list" do
      input = %{"name" => "test"}
      assert %{"name" => "test"} = SafeAtom.atomize_keys(input, [])
    end
  end

  describe "atomize_keys!/2" do
    test "atomizes all keys when all are known" do
      input = %{"name" => "test", "id" => 123}
      assert %{name: "test", id: 123} = SafeAtom.atomize_keys!(input, [:name, :id])
    end

    test "raises for unknown string keys" do
      input = %{"name" => "test", "unknown" => "value"}

      assert_raise ArgumentError, ~r/Unknown key: "unknown"/, fn ->
        SafeAtom.atomize_keys!(input, [:name])
      end
    end

    test "raises for unknown atom keys" do
      input = %{name: "test", unknown: "value"}

      assert_raise ArgumentError, ~r/Unknown key: :unknown/, fn ->
        SafeAtom.atomize_keys!(input, [:name])
      end
    end
  end

  describe "atomize_keys_deep/2" do
    test "recursively atomizes nested maps" do
      input = %{
        "action" => "read",
        "params" => %{"path" => "/tmp", "content" => "data"}
      }

      result =
        SafeAtom.atomize_keys_deep(input,
          known_keys: [:action, :params],
          nested: %{params: [known_keys: [:path, :content]]}
        )

      assert %{action: "read", params: %{path: "/tmp", content: "data"}} = result
    end

    test "handles missing nested keys" do
      input = %{"action" => "read"}

      result =
        SafeAtom.atomize_keys_deep(input,
          known_keys: [:action, :params],
          nested: %{params: [known_keys: [:path]]}
        )

      assert %{action: "read"} = result
    end

    test "preserves unknown keys at each level" do
      input = %{
        "action" => "read",
        "unknown" => "top",
        "params" => %{"path" => "/tmp", "extra" => "nested"}
      }

      result =
        SafeAtom.atomize_keys_deep(input,
          known_keys: [:action, :params],
          nested: %{params: [known_keys: [:path]]}
        )

      assert %{"unknown" => "top", action: "read", params: %{"extra" => "nested", path: "/tmp"}} =
               result
    end
  end

  # ==========================================================================
  # Arbor-specific helpers
  # ==========================================================================

  describe "signal_categories/0" do
    test "returns known categories" do
      categories = SafeAtom.signal_categories()

      assert :activity in categories
      assert :security in categories
      assert :metrics in categories
      assert :traces in categories
      assert :logs in categories
      assert :alerts in categories
      assert :custom in categories
      assert :unknown in categories
    end
  end

  describe "subject_types/0" do
    test "returns known subject types" do
      types = SafeAtom.subject_types()

      assert :agent in types
      assert :session in types
      assert :task in types
      assert :action in types
      assert :event in types
      assert :signal in types
      assert :capability in types
      assert :identity in types
      assert :unknown in types
    end
  end

  describe "to_category/1" do
    test "converts known category strings" do
      assert :activity = SafeAtom.to_category("activity")
      assert :security = SafeAtom.to_category("security")
      assert :metrics = SafeAtom.to_category("metrics")
    end

    test "returns :unknown for unknown category strings" do
      assert :unknown = SafeAtom.to_category("malicious_category")
      assert :unknown = SafeAtom.to_category("attacker_injected")
    end

    test "passes through known category atoms" do
      assert :activity = SafeAtom.to_category(:activity)
      assert :security = SafeAtom.to_category(:security)
    end

    test "returns :unknown for unknown category atoms" do
      assert :unknown = SafeAtom.to_category(:bogus_category)
    end
  end

  describe "to_subject_type/1" do
    test "converts known subject type strings" do
      assert :agent = SafeAtom.to_subject_type("agent")
      assert :session = SafeAtom.to_subject_type("session")
      assert :task = SafeAtom.to_subject_type("task")
    end

    test "returns :unknown for unknown subject type strings" do
      assert :unknown = SafeAtom.to_subject_type("evil_prefix")
      assert :unknown = SafeAtom.to_subject_type("injection")
    end

    test "passes through known subject type atoms" do
      assert :agent = SafeAtom.to_subject_type(:agent)
    end

    test "returns :unknown for unknown subject type atoms" do
      assert :unknown = SafeAtom.to_subject_type(:bogus_type)
    end
  end

  describe "decode_event_type/1" do
    test "decodes valid event type strings" do
      assert {:activity, :agent_started} = SafeAtom.decode_event_type("activity:agent_started")
      assert {:security, :auth_failed} = SafeAtom.decode_event_type("security:auth_failed")
    end

    test "returns :unknown category for invalid categories" do
      {category, _type} = SafeAtom.decode_event_type("evil:attack")
      assert :unknown = category
    end

    test "returns :unknown type for unknown signal types" do
      {_category, type} = SafeAtom.decode_event_type("activity:completely_unknown_type_xyz123")
      assert :unknown = type
    end

    test "decodes atom event types" do
      assert {:activity, :started} = SafeAtom.decode_event_type(:"activity:started")
    end

    test "handles single value without colon" do
      assert {:unknown, :activity} = SafeAtom.decode_event_type("activity")
    end
  end

  describe "encode_event_type/2" do
    test "encodes category and signal type to atom" do
      assert :"activity:agent_started" = SafeAtom.encode_event_type(:activity, :agent_started)
      assert :"security:violation" = SafeAtom.encode_event_type(:security, :violation)
    end
  end

  describe "infer_subject_type/1" do
    test "infers known subject types from ID prefix" do
      assert :agent = SafeAtom.infer_subject_type("agent_001")
      assert :session = SafeAtom.infer_subject_type("session_abc123")
      assert :task = SafeAtom.infer_subject_type("task_xyz")
    end

    test "returns :unknown for unknown prefixes" do
      assert :unknown = SafeAtom.infer_subject_type("malicious_injection")
      assert :unknown = SafeAtom.infer_subject_type("evil_attack_123")
    end

    test "returns :unknown for IDs without underscore" do
      assert :unknown = SafeAtom.infer_subject_type("nounderscorehere")
    end

    test "handles multiple underscores by taking first segment" do
      assert :agent = SafeAtom.infer_subject_type("agent_with_many_parts")
    end
  end
end
