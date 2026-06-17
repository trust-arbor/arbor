defmodule Arbor.Memory.AuthorizationTest do
  # NOT async: starts the global Security stack and mutates global security
  # config (signing/identity off). The Memory facade now FAILS CLOSED in all
  # environments — there is no permissive dev/test fallback — so every
  # "...when security permits" test must bring Security up for real and grant
  # the caller a genuine capability. Enforcement is real here: each test runs
  # with `Arbor.Security.healthy?() == true`.
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :integration

  @agent_id "test_agent_auth"
  @caller_id "agent_caller"

  # Security config keys that gate extra infrastructure we don't want to start
  # for these capability-only tests. Mirrors AuthorizationE2ETest.
  @security_config_keys [
    :reflex_checking_enabled,
    :capability_signing_required,
    :strict_identity_mode,
    :identity_verification,
    :approval_guard_enabled,
    :invocation_receipts_enabled
  ]

  setup_all do
    originals =
      Enum.map(@security_config_keys, fn key ->
        {key, Application.get_env(:arbor_security, key)}
      end)

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
    # Bring up the Security infrastructure required for real authorization.
    # These are normally started by Arbor.Security.Application, but
    # start_children: false in test config disables that.
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.Identity.NonceCache)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.Constraint.RateLimiter)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)

    # The whole point of this suite post-fail-closed: enforcement is REAL.
    assert Arbor.Security.healthy?(),
           "Security system must be healthy — the Memory facade fails closed and these tests exercise real capability checks"

    # Grant the shared caller a wildcard memory capability so each
    # `authorize_*` facade call has a genuine capability to match against.
    grant_memory_cap(@caller_id)

    :ok
  end

  # Grant the caller a wildcard memory capability via the real Security facade
  # so the `authorize_*` calls below return :ok through genuine enforcement.
  # `arbor://memory/**` covers every
  # `arbor://memory/{init,cleanup,read,write,search}/<agent>` resource the
  # facade checks.
  defp grant_memory_cap(caller_id) do
    {:ok, _cap} =
      Arbor.Security.grant(
        principal: caller_id,
        resource: "arbor://memory/**"
      )

    :ok
  end

  describe "authorize_init/3" do
    test "delegates to init_for_agent when security permits" do
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

  describe "Memory.when_security_unavailable/0 (H6 regression — fails closed)" do
    test "security regression (H6): denies whenever Security is unavailable" do
      # H6: pre-fix, the Memory facade's internal authorize/3 returned :ok
      # whenever Code.ensure_loaded?(Arbor.Security) returned false or the
      # Security GenServer was unreachable. In dev/test that meant any partial
      # outage of the security subsystem silently turned every Memory
      # operation into an unauthenticated success. The facade now FAILS CLOSED
      # in ALL environments — there is no permissive mode — so this seam must
      # always deny.
      assert {:error, :security_unavailable} = Arbor.Memory.when_security_unavailable(),
             "Memory facade must deny when Security is unavailable — H6 fail-closed regression"
    end

    test "security regression (H6): fail-closed has no permissive escape hatch" do
      # Explicitly guard against re-introducing a dev/test permissive mode:
      # there is no application env that flips this seam back to :ok.
      Application.put_env(:arbor_memory, :strict_facade_mode, false)

      on_exit(fn -> Application.delete_env(:arbor_memory, :strict_facade_mode) end)

      assert {:error, :security_unavailable} = Arbor.Memory.when_security_unavailable(),
             "No application env may turn the fail-closed seam back into a permissive :ok"
    end
  end

  # Helpers

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end
end
