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
end
