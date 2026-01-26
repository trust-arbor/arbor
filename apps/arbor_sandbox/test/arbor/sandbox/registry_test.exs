defmodule Arbor.Sandbox.RegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Sandbox.Registry

  setup do
    # Ensure registry is running for tests
    case Registry.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear any existing registrations
    {:ok, sandboxes} = Registry.list()
    for sandbox <- sandboxes, do: Registry.unregister(sandbox.id)

    :ok
  end

  describe "register/1" do
    test "registers a sandbox" do
      sandbox = %{id: "sbx_1", agent_id: "agent_1", level: :limited}
      assert :ok = Registry.register(sandbox)
    end
  end

  describe "get/1" do
    test "retrieves sandbox by id" do
      sandbox = %{id: "sbx_2", agent_id: "agent_2", level: :pure}
      :ok = Registry.register(sandbox)

      assert {:ok, ^sandbox} = Registry.get("sbx_2")
    end

    test "retrieves sandbox by agent_id" do
      sandbox = %{id: "sbx_3", agent_id: "agent_3", level: :full}
      :ok = Registry.register(sandbox)

      assert {:ok, ^sandbox} = Registry.get("agent_3")
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Registry.get("nonexistent")
    end
  end

  describe "unregister/1" do
    test "removes a sandbox" do
      sandbox = %{id: "sbx_4", agent_id: "agent_4", level: :limited}
      :ok = Registry.register(sandbox)
      :ok = Registry.unregister("sbx_4")

      assert {:error, :not_found} = Registry.get("sbx_4")
      assert {:error, :not_found} = Registry.get("agent_4")
    end

    test "handles unregistering nonexistent sandbox" do
      assert :ok = Registry.unregister("nonexistent")
    end
  end

  describe "list/1" do
    test "lists all sandboxes" do
      s1 = %{id: "sbx_5", agent_id: "agent_5", level: :limited}
      s2 = %{id: "sbx_6", agent_id: "agent_6", level: :pure}
      :ok = Registry.register(s1)
      :ok = Registry.register(s2)

      assert {:ok, sandboxes} = Registry.list()
      assert length(sandboxes) == 2
    end

    test "filters by level" do
      s1 = %{id: "sbx_7", agent_id: "agent_7", level: :limited}
      s2 = %{id: "sbx_8", agent_id: "agent_8", level: :pure}
      :ok = Registry.register(s1)
      :ok = Registry.register(s2)

      assert {:ok, [^s2]} = Registry.list(level: :pure)
    end

    test "limits results" do
      for i <- 1..5 do
        :ok =
          Registry.register(%{id: "sbx_lim_#{i}", agent_id: "agent_lim_#{i}", level: :limited})
      end

      assert {:ok, sandboxes} = Registry.list(limit: 2)
      assert length(sandboxes) == 2
    end
  end
end
