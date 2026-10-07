defmodule Arbor.Orchestrator.HandlerRegistryAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-007"

  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry

  @legacy_override_key {Registry, :custom_handlers}
  @replacement_target_key {__MODULE__, :replacement_target}
  @authority_directory :arbor_orchestrator_handler_registry_authority

  defmodule ReplacementStartHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler
    @target_key {Arbor.Orchestrator.HandlerRegistryAuthoritySecurityRegressionTest,
                 :replacement_target}

    @impl true
    def execute(_node, _context, _graph, _opts) do
      target = :persistent_term.get(@target_key, nil)
      if is_pid(target), do: send(target, :replacement_start_executed)
      %Outcome{status: :success}
    end
  end

  setup do
    :persistent_term.put(@replacement_target_key, self())

    on_exit(fn ->
      :persistent_term.erase(@replacement_target_key)
      :persistent_term.erase(@legacy_override_key)
    end)

    :ok
  end

  @tag :security_regression
  @tag spec: "KSEC-007"
  test "security regression: an arbitrary caller cannot replace Engine dispatch" do
    assert {:error, :unauthorized} = Registry.register("start", ReplacementStartHandler)
    assert {:error, :unauthorized} = Registry.unregister("start")
    assert {:error, :unauthorized} = Registry.reset_custom_handlers()
    assert {:error, :unauthorized} = Registry.restore_custom_handlers(%{})

    # The old implementation resolved this process-global value before the
    # owner-protected HandlerRegistry. Keep the direct write in the regression
    # so restoring the legacy lookup cannot silently reopen the bypass.
    :persistent_term.put(@legacy_override_key, %{"start" => ReplacementStartHandler})

    dot = """
    digraph DispatchAuthority {
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, cache: false)
    assert result.final_outcome.status == :success
    refute_receive :replacement_start_executed

    assert {:ok, Arbor.Orchestrator.Handlers.StartHandler} = Arbor.Common.resolve_handler("start")
  end

  @tag :security_regression
  test "security regression: core registration and locking require owner custody" do
    assert {:error, :core_registration_authority_required} =
             Arbor.Common.lock_core_handlers()

    assert {:error, :invalid_core_registration_authority} =
             Arbor.Common.register_core_handler(
               "start",
               ReplacementStartHandler,
               %{},
               :crypto.strong_rand_bytes(32)
             )

    authority = Process.whereis(Arbor.Orchestrator.Handlers.RegistryAuthority)

    assert {:error, :invalid_core_registration_authority} =
             forged_call(
               authority,
               {:register_core, "start", ReplacementStartHandler, %{},
                :crypto.strong_rand_bytes(32)}
             )

    %{custody_table: custody_table} =
      :sys.get_state(Arbor.Orchestrator.Handlers.RegistryAuthority)

    assert_raise ArgumentError, fn -> :ets.lookup(custody_table, :custody) end

    assert {:ok, Arbor.Orchestrator.Handlers.StartHandler} = Arbor.Common.resolve_handler("start")
  end

  @tag :security_regression
  test "security regression: restarting the authority cannot rewrite locked dispatch" do
    authority_module = Arbor.Orchestrator.Handlers.RegistryAuthority
    old_authority = Process.whereis(authority_module)
    assert is_pid(old_authority)

    assert :ok = Supervisor.terminate_child(Arbor.Orchestrator.Supervisor, authority_module)

    try do
      assert {:ok, new_authority} =
               Supervisor.restart_child(Arbor.Orchestrator.Supervisor, authority_module)

      refute new_authority == old_authority
      assert :ok = Registry.register_core_handlers()

      assert {:ok, Arbor.Orchestrator.Handlers.StartHandler} =
               Arbor.Common.resolve_handler("start")

      assert {:error, :unauthorized} = Registry.register("start", ReplacementStartHandler)
    after
      case Process.whereis(authority_module) do
        nil -> Supervisor.restart_child(Arbor.Orchestrator.Supervisor, authority_module)
        _pid -> :ok
      end
    end
  end

  @tag :security_regression
  test "security regression: kill, directory squat, and fresh registry cannot seize core dispatch" do
    authority_module = Arbor.Orchestrator.Handlers.RegistryAuthority
    supervisor = Arbor.Orchestrator.Supervisor
    fake_custody = :crypto.strong_rand_bytes(32)

    assert :ok = Supervisor.terminate_child(supervisor, authority_module)
    assert Process.whereis(authority_module) == nil
    true = Process.register(self(), authority_module)

    @authority_directory =
      :ets.new(@authority_directory, [:named_table, :protected, :set])

    true =
      :ets.insert(
        @authority_directory,
        {:custody_sha256, :crypto.hash(:sha256, fake_custody)}
      )

    attack_result =
      try do
        handler_registry_child_id = Arbor.Common.handler_registry_child_id()
        assert :ok = Supervisor.terminate_child(supervisor, handler_registry_child_id)
        delete_registry_heir_table!()

        assert {:ok, _registry_pid} =
                 Supervisor.restart_child(supervisor, handler_registry_child_id)

        refute Arbor.Common.core_handlers_locked?()
        assert {:error, :not_found} = Arbor.Common.resolve_handler("start")

        Arbor.Common.register_core_handler(
          "start",
          ReplacementStartHandler,
          %{},
          fake_custody
        )
      after
        cleanup_squatter(authority_module)
        ensure_supervised_child_started(supervisor, Arbor.Common.handler_registry_child_id())
        ensure_supervised_child_started(supervisor, authority_module)
        assert :ok = Registry.register_core_handlers()
      end

    assert {:error, :invalid_core_registration_authority} = attack_result
    assert {:ok, Arbor.Orchestrator.Handlers.StartHandler} = Arbor.Common.resolve_handler("start")
  end

  defp forged_call(asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(Arbor.Common.handler_registry_pid(), {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged handler-registry authority call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end

  defp delete_registry_heir_table! do
    heir = :ets.info(:handler_registry, :owner)
    assert is_pid(heir)
    monitor = Process.monitor(heir)
    Process.exit(heir, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^heir, :killed}, 1_000
    assert :ets.whereis(:handler_registry) == :undefined
  end

  defp cleanup_squatter(authority_module) do
    if :ets.whereis(@authority_directory) != :undefined and
         :ets.info(@authority_directory, :owner) == self() do
      :ets.delete(@authority_directory)
    end

    if Process.whereis(authority_module) == self() do
      Process.unregister(authority_module)
    end
  end

  defp ensure_supervised_child_started(supervisor, child_id) do
    case Enum.find(Supervisor.which_children(supervisor), fn
           {^child_id, _pid, _type, _modules} -> true
           _other -> false
         end) do
      {^child_id, pid, _type, _modules} when is_pid(pid) ->
        :ok

      {^child_id, :undefined, _type, _modules} ->
        case Supervisor.restart_child(supervisor, child_id) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
        end

      nil ->
        flunk("missing supervised child #{inspect(child_id)}")
    end
  end
end
