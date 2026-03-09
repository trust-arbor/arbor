defmodule Arbor.Memory.AuthorizationE2ETest do
  @moduledoc """
  End-to-end tests for memory authorization with the full Security stack.

  Unlike the unit-level AuthorizationTest (which runs without security
  infrastructure and relies on permissive fallback), these tests start
  the full Security supervision tree and verify that capabilities are
  correctly enforced — both grant and deny paths — for each `authorize_*`
  function in the Memory facade.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  @agent_id "e2e_auth_agent"

  # Security config keys that must be disabled for clean test execution.
  # Each of these gates additional infrastructure (reflexes, signing, etc.)
  # that would require starting even more processes. We only need the core
  # CapabilityStore + Identity.Registry + SystemAuthority pipeline.
  @security_config_keys [
    :reflex_checking_enabled,
    :capability_signing_required,
    :strict_identity_mode,
    :approval_guard_enabled,
    :invocation_receipts_enabled
  ]

  setup_all do
    # Save original security config values
    originals =
      Enum.map(@security_config_keys, fn key ->
        {key, Application.get_env(:arbor_security, key)}
      end)

    # Disable all security features that require extra infrastructure
    for key <- @security_config_keys do
      Application.put_env(:arbor_security, key, false)
    end

    on_exit(fn ->
      for {key, original} <- originals do
        case original do
          nil -> Application.delete_env(:arbor_security, key)
          val -> Application.put_env(:arbor_security, key, val)
        end
      end
    end)

    :ok
  end

  setup do
    # Start the security infrastructure required for authorization.
    # These are normally started by Arbor.Security.Application but
    # start_children: false in test config disables that.
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.Identity.NonceCache)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.Constraint.RateLimiter)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)

    # Verify security is healthy before running tests
    assert Arbor.Security.healthy?(),
           "Security system must be healthy for e2e auth tests"

    :ok
  end

  # ============================================================================
  # Authorized Operations — Happy Path
  # ============================================================================

  describe "authorized read" do
    setup do
      agent_id = "#{@agent_id}_read_ok"
      caller = unique_caller()
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/read/#{agent_id}"
        )

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_read succeeds with read capability", %{agent_id: agent_id, caller: caller} do
      result = Arbor.Memory.authorize_read(caller, agent_id)
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "unauthorized read" do
    setup do
      agent_id = "#{@agent_id}_read_deny"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "authorize_read returns unauthorized without capability", %{agent_id: agent_id} do
      caller = unique_caller()
      result = Arbor.Memory.authorize_read(caller, agent_id)
      assert {:error, {:unauthorized, reason}} = result
      assert reason != nil
    end
  end

  describe "authorized write" do
    setup do
      agent_id = "#{@agent_id}_write_ok"
      caller = unique_caller()
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/write/#{agent_id}"
        )

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_write succeeds with write capability", %{
      agent_id: agent_id,
      caller: caller
    } do
      wm = Arbor.Memory.WorkingMemoryStore.load_working_memory(agent_id)
      result = Arbor.Memory.authorize_write(caller, agent_id, wm)
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "unauthorized write" do
    setup do
      agent_id = "#{@agent_id}_write_deny"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "authorize_write returns unauthorized without capability", %{agent_id: agent_id} do
      caller = unique_caller()
      wm = Arbor.Memory.WorkingMemoryStore.load_working_memory(agent_id)

      result = Arbor.Memory.authorize_write(caller, agent_id, wm)
      assert {:error, {:unauthorized, reason}} = result
      assert reason != nil
    end

    test "authorize_write does not persist data when unauthorized", %{agent_id: agent_id} do
      caller = unique_caller()
      wm = Arbor.Memory.WorkingMemoryStore.load_working_memory(agent_id)
      modified_wm = Map.put(wm, :notes, ["should not be saved"])

      _result = Arbor.Memory.authorize_write(caller, agent_id, modified_wm)

      # Verify working memory was NOT modified
      current_wm = Arbor.Memory.WorkingMemoryStore.load_working_memory(agent_id)
      refute Map.get(current_wm, :notes) == ["should not be saved"]
    end
  end

  describe "authorized search" do
    setup do
      agent_id = "#{@agent_id}_search_ok"
      caller = unique_caller()
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: true)

      Arbor.Memory.add_knowledge(agent_id, %{
        type: :fact,
        content: "searchable e2e knowledge"
      })

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/search/#{agent_id}"
        )

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_search succeeds with search capability", %{
      agent_id: agent_id,
      caller: caller
    } do
      result = Arbor.Memory.authorize_search(caller, agent_id, "searchable")
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorized index (uses write URI)" do
    setup do
      agent_id = "#{@agent_id}_index_ok"
      caller = unique_caller()
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/write/#{agent_id}"
        )

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_index succeeds with write capability", %{
      agent_id: agent_id,
      caller: caller
    } do
      result =
        Arbor.Memory.authorize_index(caller, agent_id, "indexed e2e content", %{type: :fact})

      assert {:ok, _entry_id} = result
    end
  end

  describe "authorized recall (uses read URI)" do
    setup do
      agent_id = "#{@agent_id}_recall_ok"
      caller = unique_caller()
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      Arbor.Memory.index(agent_id, "important recall fact", %{type: :fact})

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/read/#{agent_id}"
        )

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_recall succeeds with read capability", %{
      agent_id: agent_id,
      caller: caller
    } do
      result = Arbor.Memory.authorize_recall(caller, agent_id, "recall fact")
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorized add_knowledge (uses write URI)" do
    setup do
      agent_id = "#{@agent_id}_know_ok"
      caller = unique_caller()
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: true)

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/write/#{agent_id}"
        )

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_add_knowledge succeeds with write capability", %{
      agent_id: agent_id,
      caller: caller
    } do
      result =
        Arbor.Memory.authorize_add_knowledge(caller, agent_id, %{
          type: :fact,
          content: "authorized knowledge entry"
        })

      assert {:ok, _node_id} = result
    end
  end

  describe "authorized init" do
    setup do
      agent_id = "#{@agent_id}_init_ok"
      caller = unique_caller()

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/init/#{agent_id}"
        )

      on_exit(fn ->
        try do
          Arbor.Memory.cleanup_for_agent(agent_id)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_init succeeds with init capability", %{
      agent_id: agent_id,
      caller: caller
    } do
      result = Arbor.Memory.authorize_init(caller, agent_id)
      assert {:ok, _pid} = result
    end
  end

  describe "unauthorized init" do
    test "authorize_init returns unauthorized without capability" do
      caller = unique_caller()
      agent_id = "#{@agent_id}_init_deny"

      result = Arbor.Memory.authorize_init(caller, agent_id)
      assert {:error, {:unauthorized, _}} = result
    end
  end

  describe "authorized cleanup" do
    setup do
      agent_id = "#{@agent_id}_clean_ok"
      caller = unique_caller()
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)

      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/cleanup/#{agent_id}"
        )

      %{agent_id: agent_id, caller: caller}
    end

    test "authorize_cleanup succeeds with cleanup capability", %{
      agent_id: agent_id,
      caller: caller
    } do
      assert :ok = Arbor.Memory.authorize_cleanup(caller, agent_id)
    end
  end

  describe "unauthorized cleanup" do
    setup do
      agent_id = "#{@agent_id}_clean_deny"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "authorize_cleanup returns unauthorized without capability", %{agent_id: agent_id} do
      caller = unique_caller()
      result = Arbor.Memory.authorize_cleanup(caller, agent_id)
      assert {:error, {:unauthorized, _}} = result
    end
  end

  # ============================================================================
  # Cross-Agent Isolation
  # ============================================================================

  describe "cross-agent isolation" do
    setup do
      agent_a = "#{@agent_id}_iso_a"
      agent_b = "#{@agent_id}_iso_b"
      caller = unique_caller()

      {:ok, _} = Arbor.Memory.init_for_agent(agent_a)
      {:ok, _} = Arbor.Memory.init_for_agent(agent_b)

      # Grant caller read access to agent_a ONLY
      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/read/#{agent_a}"
        )

      on_exit(fn ->
        Arbor.Memory.cleanup_for_agent(agent_a)
        Arbor.Memory.cleanup_for_agent(agent_b)
      end)

      %{agent_a: agent_a, agent_b: agent_b, caller: caller}
    end

    test "capability for agent A does not authorize read of agent B", %{
      agent_a: agent_a,
      agent_b: agent_b,
      caller: caller
    } do
      # Should succeed for agent_a
      result_a = Arbor.Memory.authorize_read(caller, agent_a)
      refute match?({:error, {:unauthorized, _}}, result_a)

      # Should fail for agent_b
      result_b = Arbor.Memory.authorize_read(caller, agent_b)
      assert {:error, {:unauthorized, _}} = result_b
    end

    test "write capability for agent A does not authorize write to agent B", %{
      agent_a: agent_a,
      agent_b: agent_b,
      caller: caller
    } do
      {:ok, _} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/write/#{agent_a}"
        )

      # Should succeed for agent_a
      result_a =
        Arbor.Memory.authorize_index(caller, agent_a, "content", %{type: :fact})

      assert {:ok, _} = result_a

      # Should fail for agent_b
      result_b =
        Arbor.Memory.authorize_index(caller, agent_b, "content", %{type: :fact})

      assert {:error, {:unauthorized, _}} = result_b
    end

    test "search capability for agent A does not authorize search of agent B", %{
      agent_a: agent_a,
      agent_b: agent_b,
      caller: caller
    } do
      {:ok, _} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/search/#{agent_a}"
        )

      result_a = Arbor.Memory.authorize_search(caller, agent_a, "query")
      refute match?({:error, {:unauthorized, _}}, result_a)

      result_b = Arbor.Memory.authorize_search(caller, agent_b, "query")
      assert {:error, {:unauthorized, _}} = result_b
    end
  end

  # ============================================================================
  # Wildcard Memory Access
  # ============================================================================

  describe "wildcard read access" do
    setup do
      agent_x = "#{@agent_id}_wread_x"
      agent_y = "#{@agent_id}_wread_y"
      caller = unique_caller()

      {:ok, _} = Arbor.Memory.init_for_agent(agent_x)
      {:ok, _} = Arbor.Memory.init_for_agent(agent_y)

      # Grant wildcard read: arbor://memory/read/**
      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/read/**"
        )

      on_exit(fn ->
        Arbor.Memory.cleanup_for_agent(agent_x)
        Arbor.Memory.cleanup_for_agent(agent_y)
      end)

      %{agent_x: agent_x, agent_y: agent_y, caller: caller}
    end

    test "wildcard read grants access to any agent's memory", %{
      agent_x: agent_x,
      agent_y: agent_y,
      caller: caller
    } do
      result_x = Arbor.Memory.authorize_read(caller, agent_x)
      refute match?({:error, {:unauthorized, _}}, result_x)

      result_y = Arbor.Memory.authorize_read(caller, agent_y)
      refute match?({:error, {:unauthorized, _}}, result_y)
    end

    test "wildcard read grants recall access for any agent", %{
      agent_x: agent_x,
      caller: caller
    } do
      Arbor.Memory.index(agent_x, "wildcard test fact", %{type: :fact})

      result = Arbor.Memory.authorize_recall(caller, agent_x, "wildcard test")
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "wildcard write access" do
    setup do
      agent_a = "#{@agent_id}_wwrite_a"
      agent_b = "#{@agent_id}_wwrite_b"
      caller = unique_caller()

      {:ok, _} = Arbor.Memory.init_for_agent(agent_a, graph_enabled: true)
      {:ok, _} = Arbor.Memory.init_for_agent(agent_b, graph_enabled: true)

      # Grant wildcard write
      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://memory/write/**"
        )

      on_exit(fn ->
        Arbor.Memory.cleanup_for_agent(agent_a)
        Arbor.Memory.cleanup_for_agent(agent_b)
      end)

      %{agent_a: agent_a, agent_b: agent_b, caller: caller}
    end

    test "wildcard write grants index access to multiple agents", %{
      agent_a: agent_a,
      agent_b: agent_b,
      caller: caller
    } do
      assert {:ok, _} =
               Arbor.Memory.authorize_index(caller, agent_a, "content a", %{type: :fact})

      assert {:ok, _} =
               Arbor.Memory.authorize_index(caller, agent_b, "content b", %{type: :fact})
    end

    test "wildcard write grants add_knowledge access", %{agent_a: agent_a, caller: caller} do
      result =
        Arbor.Memory.authorize_add_knowledge(caller, agent_a, %{
          type: :fact,
          content: "wildcard knowledge"
        })

      assert {:ok, _} = result
    end

    test "wildcard write does NOT grant read access", %{agent_a: agent_a, caller: caller} do
      result = Arbor.Memory.authorize_read(caller, agent_a)
      assert {:error, {:unauthorized, _}} = result
    end
  end

  describe "root wildcard access (arbor://**)" do
    setup do
      agent_id = "#{@agent_id}_root_wild"
      caller = unique_caller()

      # arbor://** is the root wildcard — grants access to ALL resources
      {:ok, _cap} =
        Arbor.Security.grant(
          principal: caller,
          resource: "arbor://**"
        )

      %{agent_id: agent_id, caller: caller}
    end

    test "grants init, read, write, search, and cleanup", %{
      agent_id: agent_id,
      caller: caller
    } do
      # init
      assert {:ok, _pid} = Arbor.Memory.authorize_init(caller, agent_id)

      # write (index)
      assert {:ok, _entry_id} =
               Arbor.Memory.authorize_index(caller, agent_id, "full wildcard content", %{
                 type: :fact
               })

      # read
      result = Arbor.Memory.authorize_read(caller, agent_id)
      refute match?({:error, {:unauthorized, _}}, result)

      # recall (read URI)
      result = Arbor.Memory.authorize_recall(caller, agent_id, "wildcard")
      refute match?({:error, {:unauthorized, _}}, result)

      # cleanup
      assert :ok = Arbor.Memory.authorize_cleanup(caller, agent_id)
    end
  end

  # ============================================================================
  # Error Wrapping Consistency
  # ============================================================================

  describe "authorization error wrapping consistency" do
    setup do
      agent_id = "#{@agent_id}_consistency"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: true)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "all authorize_* functions wrap errors as {:error, {:unauthorized, _}}", %{
      agent_id: agent_id
    } do
      caller = unique_caller()
      wm = Arbor.Memory.WorkingMemoryStore.load_working_memory(agent_id)

      results = [
        Arbor.Memory.authorize_read(caller, agent_id),
        Arbor.Memory.authorize_write(caller, agent_id, wm),
        Arbor.Memory.authorize_recall(caller, agent_id, "query"),
        Arbor.Memory.authorize_search(caller, agent_id, "query"),
        Arbor.Memory.authorize_index(caller, agent_id, "content", %{}),
        Arbor.Memory.authorize_add_knowledge(caller, agent_id, %{
          type: :fact,
          content: "test"
        }),
        Arbor.Memory.authorize_init(caller, agent_id),
        Arbor.Memory.authorize_cleanup(caller, agent_id)
      ]

      for result <- results do
        assert {:error, {:unauthorized, reason}} = result,
               "Expected {:error, {:unauthorized, _}} but got #{inspect(result)}"

        assert reason != nil
      end
    end

    test "unauthorized error reasons are not nil" do
      caller = unique_caller()
      agent_id = "#{@agent_id}_reason_check"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)

      {:error, {:unauthorized, reason}} = Arbor.Memory.authorize_read(caller, agent_id)
      assert reason != nil

      Arbor.Memory.cleanup_for_agent(agent_id)
    end
  end

  # ============================================================================
  # Data Flow Through Authorized Path
  # ============================================================================

  describe "full authorized lifecycle" do
    setup do
      agent_id = "#{@agent_id}_lifecycle"
      caller = unique_caller()

      # Grant all necessary capabilities for the lifecycle
      for action <- ["init", "read", "write", "cleanup"] do
        {:ok, _} =
          Arbor.Security.grant(
            principal: caller,
            resource: "arbor://memory/#{action}/#{agent_id}"
          )
      end

      on_exit(fn ->
        try do
          Arbor.Memory.cleanup_for_agent(agent_id)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      %{agent_id: agent_id, caller: caller}
    end

    test "init -> index -> recall -> cleanup", %{agent_id: agent_id, caller: caller} do
      # Init
      assert {:ok, pid} = Arbor.Memory.authorize_init(caller, agent_id)
      assert is_pid(pid)

      # Index content
      assert {:ok, entry_id} =
               Arbor.Memory.authorize_index(
                 caller,
                 agent_id,
                 "Elixir uses pattern matching",
                 %{type: :fact}
               )

      assert is_binary(entry_id)

      # Recall
      assert {:ok, results} =
               Arbor.Memory.authorize_recall(caller, agent_id, "pattern matching")

      assert is_list(results)
      assert length(results) > 0

      # Cleanup
      assert :ok = Arbor.Memory.authorize_cleanup(caller, agent_id)
      refute Arbor.Memory.initialized?(agent_id)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp unique_caller do
    "agent_caller_#{:erlang.unique_integer([:positive])}"
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end
end
