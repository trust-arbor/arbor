defmodule Arbor.Memory.AuthorizationTest do
  # NOT async: when run as part of the full arbor_memory suite (as CI does —
  # one BEAM per app), a sibling test starts the Security stack, so `authorize/2`
  # here enforces for real instead of taking the permissive no-security fallback.
  # This module sets global security config to make that enforcement test-friendly
  # (signing/identity off) and grants the caller a real capability, so it passes
  # whether or not Security happens to be live. Global config + async don't mix.
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :integration

  @agent_id "test_agent_auth"
  @caller_id "agent_caller"

  setup do
    # The earlier `{:skip, …}` return was invalid — ExUnit setup callbacks may
    # only return :ok / a keyword / a map, so it raised once Security was live in
    # the full-suite BEAM. Instead, make both paths pass:
    #   * Security absent → `authorize/2` takes the permissive fallback (:ok).
    #   * Security live    → set signing/identity off and grant the caller a real
    #     `arbor://memory/**` cap so enforcement returns authorized.
    if security_loaded?() do
      prev_security =
        for key <- [:capability_signing_required, :strict_identity_mode, :identity_verification] do
          {key, Application.get_env(:arbor_security, key)}
        end

      Application.put_env(:arbor_security, :capability_signing_required, false)
      Application.put_env(:arbor_security, :strict_identity_mode, false)
      Application.put_env(:arbor_security, :identity_verification, false)

      grant_memory_cap(@caller_id)

      on_exit(fn ->
        for {key, value} <- prev_security do
          if is_nil(value),
            do: Application.delete_env(:arbor_security, key),
            else: Application.put_env(:arbor_security, key, value)
        end
      end)
    end

    :ok
  end

  # Grant the caller a wildcard memory capability so the `authorize_*` facade
  # returns :ok when the Security stack is live. The `/**` is required post-C8
  # (a concrete URI grants only its exact resource), and covers every
  # `arbor://memory/{init,cleanup,read,write,search}/<agent>` resource the facade
  # checks. Done via runtime apply to avoid a compile-time dep on arbor_security.
  defp grant_memory_cap(caller_id) do
    cap = %Arbor.Contracts.Security.Capability{
      id: "cap_memory_auth_#{System.unique_integer([:positive])}",
      principal_id: caller_id,
      resource_uri: "arbor://memory/**",
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      metadata: %{test: true}
    }

    apply(Arbor.Security.CapabilityStore, :put, [cap])
  end

  describe "authorize_init/3" do
    test "delegates to init_for_agent when security permits" do
      # Security is not loaded in memory test env — authorize/2 returns :ok
      assert {:ok, _pid} = Arbor.Memory.authorize_init(@caller_id, @agent_id)
    end

    test "accepts options" do
      assert {:ok, _pid} =
               Arbor.Memory.authorize_init(@caller_id, "#{@agent_id}_opts",
                 max_entries: 100,
                 index_enabled: true,
                 graph_enabled: false
               )
    end
  end

  describe "authorize_cleanup/2" do
    test "delegates to cleanup_for_agent when security permits" do
      {:ok, _} = Arbor.Memory.init_for_agent("#{@agent_id}_cleanup")
      assert :ok = Arbor.Memory.authorize_cleanup(@caller_id, "#{@agent_id}_cleanup")
    end
  end

  describe "authorize_index/5" do
    setup do
      agent_id = "#{@agent_id}_index"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to index when security permits", %{agent_id: agent_id} do
      assert {:ok, _entry_id} =
               Arbor.Memory.authorize_index(
                 @caller_id,
                 agent_id,
                 "test content",
                 %{type: :fact}
               )
    end
  end

  describe "authorize_recall/4" do
    setup do
      agent_id = "#{@agent_id}_recall"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      Arbor.Memory.index(agent_id, "important test fact", %{type: :fact})
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to recall when security permits", %{agent_id: agent_id} do
      assert {:ok, _results} =
               Arbor.Memory.authorize_recall(@caller_id, agent_id, "test fact")
    end
  end

  describe "authorize_search/4" do
    setup do
      agent_id = "#{@agent_id}_search"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: true)

      Arbor.Memory.add_knowledge(agent_id, %{
        type: :fact,
        content: "searchable knowledge"
      })

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to search_knowledge when security permits", %{agent_id: agent_id} do
      assert {:ok, _results} =
               Arbor.Memory.authorize_search(@caller_id, agent_id, "searchable")
    end
  end

  describe "authorize_read/3" do
    setup do
      agent_id = "#{@agent_id}_read"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to load_working_memory when security permits", %{agent_id: agent_id} do
      result = Arbor.Memory.authorize_read(@caller_id, agent_id)
      # Should not return unauthorized
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_write/3" do
    setup do
      agent_id = "#{@agent_id}_write"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to save_working_memory when security permits", %{agent_id: agent_id} do
      # Load working memory first to get a valid struct
      wm = Arbor.Memory.WorkingMemoryStore.load_working_memory(agent_id)
      result = Arbor.Memory.authorize_write(@caller_id, agent_id, wm)
      # Should not return unauthorized
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_add_knowledge/3" do
    setup do
      agent_id = "#{@agent_id}_knowledge"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: true)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to add_knowledge when security permits", %{agent_id: agent_id} do
      assert {:ok, _node_id} =
               Arbor.Memory.authorize_add_knowledge(@caller_id, agent_id, %{
                 type: :fact,
                 content: "authorized knowledge"
               })
    end
  end

  describe "function signatures" do
    test "all authorize_* functions are exported" do
      exports = Arbor.Memory.__info__(:functions)

      assert {:authorize_init, 2} in exports or {:authorize_init, 3} in exports
      assert {:authorize_cleanup, 2} in exports
      assert {:authorize_index, 3} in exports or {:authorize_index, 5} in exports
      assert {:authorize_recall, 3} in exports or {:authorize_recall, 4} in exports
      assert {:authorize_search, 3} in exports or {:authorize_search, 4} in exports
      assert {:authorize_read, 2} in exports or {:authorize_read, 3} in exports
      assert {:authorize_write, 3} in exports
      assert {:authorize_add_knowledge, 3} in exports
    end
  end

  # Grant wildcard memory capabilities when Security is running.
  # When Security is not loaded, authorize/2 permits by default.
  # Mirror EXACTLY the condition under which `Arbor.Memory`'s private
  # `authorize/2` enforces (vs. its permissive fallback): Security loaded +
  # `authorize/4` exported + `security_available?` (which is `healthy?/0` when
  # exported, else true). When that holds, real enforcement is in play and
  # AuthorizationE2ETest owns the coverage — so we skip rather than fail on this
  # test's permissive-path assumptions. (The old helper granted via unsigned
  # `CapabilityStore.put` of bare URIs, which `authorize/4` ignores — hence the
  # combined-run failures.)
  defp security_loaded? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :authorize, 4) and
      security_reports_available?()
  end

  defp security_reports_available? do
    if function_exported?(Arbor.Security, :healthy?, 0) do
      try do
        Arbor.Security.healthy?()
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end
    else
      true
    end
  end

  describe "Memory.when_security_unavailable/0 (H6 regression)" do
    setup do
      original = Application.get_env(:arbor_memory, :strict_facade_mode)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:arbor_memory, :strict_facade_mode)
        else
          Application.put_env(:arbor_memory, :strict_facade_mode, original)
        end
      end)

      :ok
    end

    test "security regression (H6): strict mode denies when Security is unavailable" do
      # H6: pre-fix, the Memory facade's internal authorize/3 returned :ok
      # whenever Code.ensure_loaded?(Arbor.Security) returned false or the
      # Security GenServer was unreachable. That meant any partial outage of
      # the security subsystem silently turned every Memory operation into
      # an unauthenticated success. In strict mode (production by default)
      # the facade must deny instead.
      Application.put_env(:arbor_memory, :strict_facade_mode, true)

      assert {:error, :security_unavailable} = Arbor.Memory.when_security_unavailable(),
             "Strict mode must deny when Security is unavailable — H6 regression"
    end

    test "permissive mode preserves the existing :ok response" do
      # Dev/test default. Existing test setups that don't bring up
      # Arbor.Security should keep working — only production flips strict on.
      Application.put_env(:arbor_memory, :strict_facade_mode, false)

      assert :ok = Arbor.Memory.when_security_unavailable()
    end
  end
end
