defmodule Arbor.Security.CapabilityStoreTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.SystemAuthority

  setup do
    # Create unique agent ID for each test
    agent_id = "agent_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # Basic CRUD operations
  # ===========================================================================

  describe "put/1 and get/1" do
    test "stores and retrieves a capability", %{agent_id: agent_id} do
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/basic")
      assert {:ok, :stored} = CapabilityStore.put(cap)
      assert {:ok, retrieved} = CapabilityStore.get(cap.id)
      assert retrieved.id == cap.id
      assert retrieved.principal_id == agent_id
    end

    test "returns not_found for unknown capability" do
      assert {:error, :not_found} =
               CapabilityStore.get("cap_nonexistent_#{:erlang.unique_integer([:positive])}")
    end

    test "returns capability_expired for expired capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/expiring",
          principal_id: agent_id,
          expires_at: DateTime.add(DateTime.utc_now(), 1)
        )

      # Store with future expiry, then manually override
      expired = %{cap | expires_at: DateTime.add(DateTime.utc_now(), -3600)}
      {:ok, :stored} = CapabilityStore.put(expired)

      assert {:error, :capability_expired} = CapabilityStore.get(expired.id)
    end
  end

  describe "list_for_principal/2" do
    test "lists capabilities for a principal", %{agent_id: agent_id} do
      {:ok, cap1} = build_capability(agent_id, "arbor://fs/read/list/1")
      {:ok, cap2} = build_capability(agent_id, "arbor://fs/read/list/2")
      {:ok, :stored} = CapabilityStore.put(cap1)
      {:ok, :stored} = CapabilityStore.put(cap2)

      {:ok, caps} = CapabilityStore.list_for_principal(agent_id)
      ids = Enum.map(caps, & &1.id)
      assert cap1.id in ids
      assert cap2.id in ids
    end

    test "returns empty list for unknown principal" do
      assert {:ok, []} =
               CapabilityStore.list_for_principal(
                 "agent_unknown_#{:erlang.unique_integer([:positive])}"
               )
    end

    test "filters expired by default", %{agent_id: agent_id} do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/expired_list",
          principal_id: agent_id,
          expires_at: DateTime.add(DateTime.utc_now(), 1)
        )

      expired = %{cap | expires_at: DateTime.add(DateTime.utc_now(), -3600)}
      {:ok, :stored} = CapabilityStore.put(expired)

      {:ok, caps} = CapabilityStore.list_for_principal(agent_id)
      refute Enum.any?(caps, &(&1.id == expired.id))
    end

    test "includes expired when include_expired: true", %{agent_id: agent_id} do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/include_expired",
          principal_id: agent_id,
          expires_at: DateTime.add(DateTime.utc_now(), 1)
        )

      expired = %{cap | expires_at: DateTime.add(DateTime.utc_now(), -3600)}
      {:ok, :stored} = CapabilityStore.put(expired)

      {:ok, caps} = CapabilityStore.list_for_principal(agent_id, include_expired: true)
      assert Enum.any?(caps, &(&1.id == expired.id))
    end
  end

  describe "find_authorizing/2" do
    test "finds capability matching resource URI", %{agent_id: agent_id} do
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/findable")
      {:ok, :stored} = CapabilityStore.put(cap)

      assert {:ok, found} = CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/findable")
      assert found.id == cap.id
    end

    test "finds capability by /** subtree grant", %{agent_id: agent_id} do
      # C8: subtree access requires an explicit /** wildcard.
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/prefix/**")
      {:ok, :stored} = CapabilityStore.put(cap)

      assert {:ok, _} =
               CapabilityStore.find_authorizing(
                 agent_id,
                 "arbor://fs/read/prefix/subpath/file.ex"
               )
    end

    test "C8: a CONCRETE grant does NOT authorize its subtree (only the exact URI)",
         %{agent_id: agent_id} do
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/exactonly")
      {:ok, :stored} = CapabilityStore.put(cap)

      # Exact resource is authorized.
      assert {:ok, _} = CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/exactonly")

      # A child path is NOT — concrete URIs no longer implicitly grant subtrees.
      assert {:error, :not_found} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/exactonly/child.txt")
    end

    test "returns not_found for unmatched resource", %{agent_id: agent_id} do
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/specific")
      {:ok, :stored} = CapabilityStore.put(cap)

      assert {:error, :not_found} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/write/specific")
    end

    test "matches glob wildcard /** patterns", %{agent_id: agent_id} do
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/**")
      {:ok, :stored} = CapabilityStore.put(cap)

      # Should match any subpath under fs/read
      assert {:ok, _} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/home/file.txt")

      assert {:ok, _} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/tmp/output.txt")

      # Should NOT match different prefix
      assert {:error, :not_found} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/write/tmp/output.txt")
    end

    test "glob /** does not match partial path segments", %{agent_id: agent_id} do
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/**")
      {:ok, :stored} = CapabilityStore.put(cap)

      # Should match subpaths under arbor://fs/read/
      assert {:ok, _} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/home/file.txt")

      # Should NOT match arbor://fs/readonly (different segment)
      assert {:error, :not_found} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/readonly/file.txt")
    end

    test "/** wildcard does not cross segment boundaries", %{agent_id: agent_id} do
      # C8: subtree coverage is via /**, and it must respect segment boundaries.
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/home/**")
      {:ok, :stored} = CapabilityStore.put(cap)

      # Should match subpath
      assert {:ok, _} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/home/file.txt")

      # Should NOT match home_config (boundary-aware)
      assert {:error, :not_found} =
               CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/home_config/file.txt")
    end

    test "security regression (H8): trailing-slash /** pattern still matches subpaths",
         %{agent_id: agent_id} do
      # H8: pre-fix, a trailing slash produced a double-slash in the prefix
      # check and wrongly denied legitimate subpaths. The matcher strips
      # trailing slashes before matching. C8: subtree coverage is now via /**,
      # so the grant uses the wildcard form; the trailing-slash normalization
      # still applies to the wildcard prefix.
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/**")
      {:ok, :stored} = CapabilityStore.put(cap)

      assert {:ok, _} =
               CapabilityStore.find_authorizing(
                 agent_id,
                 "arbor://fs/read/home/file.txt"
               ),
             "/** pattern must match subpaths — H8 regression"
    end
  end

  describe "revoke/1" do
    test "revokes an existing capability", %{agent_id: agent_id} do
      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/revoke_test")
      {:ok, :stored} = CapabilityStore.put(cap)

      assert :ok = CapabilityStore.revoke(cap.id)
      assert {:error, :not_found} = CapabilityStore.get(cap.id)
    end

    test "returns error for non-existent capability" do
      assert {:error, :not_found} =
               CapabilityStore.revoke("cap_gone_#{:erlang.unique_integer([:positive])}")
    end
  end

  describe "revoke_all/1" do
    test "revokes all capabilities for a principal", %{agent_id: agent_id} do
      {:ok, cap1} = build_capability(agent_id, "arbor://fs/read/revoke_all/1")
      {:ok, cap2} = build_capability(agent_id, "arbor://fs/read/revoke_all/2")
      {:ok, :stored} = CapabilityStore.put(cap1)
      {:ok, :stored} = CapabilityStore.put(cap2)

      assert {:ok, 2} = CapabilityStore.revoke_all(agent_id)

      {:ok, caps} = CapabilityStore.list_for_principal(agent_id)
      assert caps == []
    end
  end

  # ===========================================================================
  # Phase 7: Quota enforcement tests
  # ===========================================================================

  describe "put/1 quota enforcement" do
    setup do
      # Save original config values
      original_max_per_agent = Application.get_env(:arbor_security, :max_capabilities_per_agent)
      original_max_global = Application.get_env(:arbor_security, :max_global_capabilities)
      original_max_depth = Application.get_env(:arbor_security, :max_delegation_depth)
      original_enabled = Application.get_env(:arbor_security, :quota_enforcement_enabled)

      on_exit(fn ->
        restore_config(:max_capabilities_per_agent, original_max_per_agent)
        restore_config(:max_global_capabilities, original_max_global)
        restore_config(:max_delegation_depth, original_max_depth)
        restore_config(:quota_enforcement_enabled, original_enabled)
      end)

      :ok
    end

    test "succeeds within per-agent limit", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 5)

      for i <- 1..4 do
        {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/#{i}")
        assert {:ok, :stored} = CapabilityStore.put(cap)
      end
    end

    test "fails when per-agent limit exceeded", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 3)

      for i <- 1..3 do
        {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/#{i}")
        {:ok, :stored} = CapabilityStore.put(cap)
      end

      # 4th should fail
      {:ok, cap4} = build_capability(agent_id, "arbor://fs/read/test/4")

      assert {:error, {:quota_exceeded, :per_agent_capability_limit, context}} =
               CapabilityStore.put(cap4)

      assert context.agent_id == agent_id
      assert context.current == 3
      assert context.limit == 3
    end

    test "fails when global limit exceeded" do
      # Get current count and set limit just above it so we have room to add exactly 2
      stats = CapabilityStore.stats()
      current_count = stats.active_capabilities
      limit = current_count + 2

      Application.put_env(:arbor_security, :max_global_capabilities, limit)
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 1000)

      base = :erlang.unique_integer([:positive])

      # Should succeed (1st within limit)
      agent1 = "agent_global_test_#{base}_1"
      {:ok, cap1} = build_capability(agent1, "arbor://fs/read/test/global/#{base}/1")
      {:ok, :stored} = CapabilityStore.put(cap1)

      # Should succeed (2nd within limit)
      agent2 = "agent_global_test_#{base}_2"
      {:ok, cap2} = build_capability(agent2, "arbor://fs/read/test/global/#{base}/2")
      {:ok, :stored} = CapabilityStore.put(cap2)

      # 3rd should fail (at limit)
      agent3 = "agent_global_test_#{base}_3"
      {:ok, cap3} = build_capability(agent3, "arbor://fs/read/test/global/#{base}/3")

      assert {:error, {:quota_exceeded, :global_capability_limit, context}} =
               CapabilityStore.put(cap3)

      assert is_integer(context.current)
      assert context.limit == limit
    end

    test "fails when delegation_depth exceeds max", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_delegation_depth, 3)

      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/deep", delegation_depth: 4)

      assert {:error, {:quota_exceeded, :delegation_depth_limit, context}} =
               CapabilityStore.put(cap)

      assert context.depth == 4
      assert context.limit == 3
    end

    test "succeeds when delegation_depth equals max", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_delegation_depth, 3)

      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/exact", delegation_depth: 3)
      assert {:ok, :stored} = CapabilityStore.put(cap)
    end

    test "fails when delegation_depth is negative", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_delegation_depth, 10)

      # Manually create a capability with negative depth (bypassing validation)
      cap = %Capability{
        id: "cap_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://fs/read/test/negative",
        principal_id: agent_id,
        delegation_depth: -1,
        constraints: %{},
        metadata: %{},
        delegation_chain: [],
        granted_at: DateTime.utc_now()
      }

      assert {:error, {:quota_exceeded, :delegation_depth_limit, context}} =
               CapabilityStore.put(cap)

      assert context.depth == -1
      assert context.reason == :negative_depth
    end

    test "quota enforcement disabled ignores limits", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 2)
      Application.put_env(:arbor_security, :max_delegation_depth, 1)
      Application.put_env(:arbor_security, :quota_enforcement_enabled, false)

      # Should succeed even with depth > max
      {:ok, cap1} =
        build_capability(agent_id, "arbor://fs/read/test/no_quota/1", delegation_depth: 10)

      assert {:ok, :stored} = CapabilityStore.put(cap1)

      # Should succeed even with > max_per_agent
      {:ok, cap2} = build_capability(agent_id, "arbor://fs/read/test/no_quota/2")
      assert {:ok, :stored} = CapabilityStore.put(cap2)

      {:ok, cap3} = build_capability(agent_id, "arbor://fs/read/test/no_quota/3")
      assert {:ok, :stored} = CapabilityStore.put(cap3)
    end

    test "revoke frees quota space", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 2)

      {:ok, cap1} = build_capability(agent_id, "arbor://fs/read/test/revoke/1")
      {:ok, :stored} = CapabilityStore.put(cap1)

      {:ok, cap2} = build_capability(agent_id, "arbor://fs/read/test/revoke/2")
      {:ok, :stored} = CapabilityStore.put(cap2)

      # At limit
      {:ok, cap3} = build_capability(agent_id, "arbor://fs/read/test/revoke/3")

      assert {:error, {:quota_exceeded, :per_agent_capability_limit, _}} =
               CapabilityStore.put(cap3)

      # Revoke one
      :ok = CapabilityStore.revoke(cap1.id)

      # Now should succeed
      assert {:ok, :stored} = CapabilityStore.put(cap3)
    end
  end

  describe "stats/0 quota information" do
    test "includes quota limits in stats" do
      stats = CapabilityStore.stats()

      assert Map.has_key?(stats, :quota_max_per_agent)
      assert Map.has_key?(stats, :quota_max_global)
      assert Map.has_key?(stats, :quota_max_delegation_depth)
      assert Map.has_key?(stats, :quota_enforcement_enabled)

      assert is_integer(stats.quota_max_per_agent)
      assert is_integer(stats.quota_max_global)
      assert is_integer(stats.quota_max_delegation_depth)
      assert is_boolean(stats.quota_enforcement_enabled)
    end
  end

  # ===========================================================================
  # VP-05D2A0: list_valid_for_principal/2 and get_valid_disclosure/3
  # ===========================================================================

  describe "list_valid_for_principal/2 (VP-05D2A0 hardened ordinary-candidate source)" do
    @tag spec: "VP-05D2A0"
    test "excludes an expired capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://ai/generate/vsp_expired",
          principal_id: agent_id,
          expires_at: DateTime.add(DateTime.utc_now(), 1)
        )

      expired = %{cap | expires_at: DateTime.add(DateTime.utc_now(), -3600)}
      {:ok, :stored} = CapabilityStore.put(expired)

      {:ok, caps} = CapabilityStore.list_valid_for_principal(agent_id)
      refute Enum.any?(caps, &(&1.id == expired.id))
    end

    @tag spec: "VP-05D2A0"
    test "excludes an unsigned capability when signing is required", %{agent_id: agent_id} do
      # config/test.exs sets capability_signing_required: false by default (so
      # the rest of this suite's unsigned fixtures keep working) — enable it
      # explicitly here to exercise the "signed when required" branch.
      original = Application.get_env(:arbor_security, :capability_signing_required)
      Application.put_env(:arbor_security, :capability_signing_required, true)
      on_exit(fn -> restore_config(:capability_signing_required, original) end)

      {:ok, cap} = build_capability(agent_id, "arbor://ai/generate/vsp_unsigned")
      {:ok, :stored} = CapabilityStore.put(cap)

      {:ok, caps} = CapabilityStore.list_valid_for_principal(agent_id)
      refute Enum.any?(caps, &(&1.id == cap.id))
    end

    @tag spec: "VP-05D2A0"
    test "excludes a capability whose scope does not match the live request", %{
      agent_id: agent_id
    } do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://ai/generate/vsp_scoped",
          principal_id: agent_id,
          session_id: "session_only_this_one"
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      {:ok, caps} =
        CapabilityStore.list_valid_for_principal(agent_id, session_id: "some_other_session")

      refute Enum.any?(caps, &(&1.id == signed.id))

      {:ok, caps_matching} =
        CapabilityStore.list_valid_for_principal(agent_id, session_id: "session_only_this_one")

      assert Enum.any?(caps_matching, &(&1.id == signed.id))
    end

    @tag spec: "VP-05D2A0"
    test "excludes a disclosure-namespaced capability even when otherwise valid", %{
      agent_id: agent_id
    } do
      cap = build_disclosure_capability(agent_id)
      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      {:ok, caps} =
        CapabilityStore.list_valid_for_principal(agent_id,
          session_id: signed.session_id,
          task_id: signed.task_id,
          principal_scope: signed.principal_scope
        )

      refute Enum.any?(caps, &(&1.id == signed.id))
    end

    @tag spec: "VP-05D2A0"
    test "includes a valid current signed scoped ordinary capability (base-fail regression)", %{
      agent_id: agent_id
    } do
      {:ok, cap} = build_capability(agent_id, "arbor://ai/generate/vsp_valid")
      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      {:ok, caps} = CapabilityStore.list_valid_for_principal(agent_id)
      assert Enum.any?(caps, &(&1.id == signed.id))
    end
  end

  describe "get_valid_disclosure/3 (VP-05D2A0 store-linearized disclosure fetch)" do
    @tag spec: "VP-05D2A0"
    test "not_found for an unknown id", %{agent_id: agent_id} do
      assert {:error, :not_found} =
               CapabilityStore.get_valid_disclosure("cap_nonexistent_disclosure", agent_id)
    end

    @tag spec: "VP-05D2A0"
    test "not_disclosure_capability for an id outside the disclosure namespace", %{
      agent_id: agent_id
    } do
      {:ok, cap} = build_capability(agent_id, "arbor://ai/generate/not_disclosure")
      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      assert {:error, :not_disclosure_capability} =
               CapabilityStore.get_valid_disclosure(signed.id, agent_id)
    end

    @tag spec: "VP-05D2A0"
    test "wrong_principal when the id belongs to a different agent", %{agent_id: agent_id} do
      cap = build_disclosure_capability(agent_id)
      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      other_agent = "agent_#{:erlang.unique_integer([:positive])}"

      assert {:error, :disclosure_capability_wrong_principal} =
               CapabilityStore.get_valid_disclosure(signed.id, other_agent)
    end

    @tag spec: "VP-05D2A0"
    test "always requires a signature, even when global capability_signing_required? is false",
         %{agent_id: agent_id} do
      original = Application.get_env(:arbor_security, :capability_signing_required)
      Application.put_env(:arbor_security, :capability_signing_required, false)

      on_exit(fn -> restore_config(:capability_signing_required, original) end)

      cap = build_disclosure_capability(agent_id)
      {:ok, :stored} = CapabilityStore.put(cap)

      scope = [
        session_id: cap.session_id,
        task_id: cap.task_id,
        principal_scope: cap.principal_scope
      ]

      assert {:error, :disclosure_capability_rejected} =
               CapabilityStore.get_valid_disclosure(cap.id, agent_id, scope)
    end

    @tag spec: "VP-05D2A0"
    test "returns a valid signed, scoped disclosure capability", %{agent_id: agent_id} do
      cap = build_disclosure_capability(agent_id)
      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      scope = [
        session_id: signed.session_id,
        task_id: signed.task_id,
        principal_scope: signed.principal_scope
      ]

      assert {:ok, found} = CapabilityStore.get_valid_disclosure(signed.id, agent_id, scope)
      assert found.id == signed.id
    end

    @tag spec: "VP-05D2A0"
    test "deterministic: revoke-before-validation denies (sequential, no concurrency needed)",
         %{agent_id: agent_id} do
      cap = build_disclosure_capability(agent_id)
      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      scope = [
        session_id: signed.session_id,
        task_id: signed.task_id,
        principal_scope: signed.principal_scope
      ]

      assert :ok = CapabilityStore.revoke(signed.id)

      assert {:error, :not_found} =
               CapabilityStore.get_valid_disclosure(signed.id, agent_id, scope)
    end

    @tag spec: "VP-05D2A0"
    test "deterministic: mailbox order is the linearization point (validation enqueued before revoke)",
         %{agent_id: agent_id} do
      cap = build_disclosure_capability(agent_id)
      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      scope = [
        session_id: signed.session_id,
        task_id: signed.task_id,
        principal_scope: signed.principal_scope
      ]

      pid = Process.whereis(CapabilityStore)
      :sys.suspend(pid)

      validate_task =
        Task.async(fn -> CapabilityStore.get_valid_disclosure(signed.id, agent_id, scope) end)

      wait_until_queue_len(pid, 1)

      revoke_task = Task.async(fn -> CapabilityStore.revoke(signed.id) end)
      wait_until_queue_len(pid, 2)

      :sys.resume(pid)

      assert {:ok, found} = Task.await(validate_task)
      assert found.id == signed.id
      assert :ok = Task.await(revoke_task)

      # The revoke, second in FIFO mailbox order, still took effect immediately after.
      assert {:error, :not_found} =
               CapabilityStore.get_valid_disclosure(signed.id, agent_id, scope)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp build_disclosure_capability(agent_id) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    unique = :erlang.unique_integer([:positive])

    %Capability{
      id: "cap_disclosure_test_#{unique}",
      resource_uri: "arbor://egress/disclose/" <> token,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
      delegation_depth: 0,
      max_uses: nil,
      session_id: "session_#{unique}",
      task_id: "task_#{unique}",
      principal_scope: "human_#{unique}",
      constraints: %{
        disclosure: %{
          kind: :interactive_human,
          destination: "api.example.com",
          provider: "anthropic",
          runtime: "cloud"
        }
      },
      delegation_chain: [],
      metadata: %{}
    }
  end

  defp wait_until_queue_len(pid, min_len), do: wait_until_queue_len(pid, min_len, 400)

  defp wait_until_queue_len(_pid, _min_len, 0),
    do: flunk("timed out waiting for message queue length")

  defp wait_until_queue_len(pid, min_len, retries) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n >= min_len ->
        :ok

      _ ->
        Process.sleep(5)
        wait_until_queue_len(pid, min_len, retries - 1)
    end
  end

  defp build_capability(agent_id, resource_uri, opts \\ []) do
    Capability.new(
      resource_uri: resource_uri,
      principal_id: agent_id,
      delegation_depth: Keyword.get(opts, :delegation_depth, 3),
      constraints: Keyword.get(opts, :constraints, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)
end
