defmodule Arbor.Agent.AuthorizationTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.{Character, Lifecycle, Profile, ProfileStore}
  alias Arbor.Agent.Registry, as: AgentRegistry
  alias Arbor.Agent.Test.TrustTopology
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security

  @moduletag :fast
  @moduletag :integration
  @profiles :arbor_agent_profiles
  @effects [
    {Lifecycle, :create, 2},
    {Lifecycle, :stop, 1},
    {Lifecycle, :destroy, 1},
    {Lifecycle, :restore, 1}
  ]
  @security_settings [
    identity_verification: false,
    strict_identity_mode: false,
    capability_signing_required: false,
    reflex_checking_enabled: false,
    uri_registry_enforcement: false,
    policy_enforcer_enabled: false,
    approval_guard_enabled: false,
    egress_gate_enforcing: false,
    consensus_escalation_enabled: true,
    use_interaction_router_for_approval: false
  ]

  defmodule ApprovalProbe do
    # Existing Security consensus injection seam. The real Security facade,
    # capability lookup, constraint evaluation and escalation still execute.
    def healthy?, do: true
    def submit(%{topic: :authorization_request}, _opts), do: {:ok, "lifecycle-pending-fixture"}
  end

  defmodule StubHost do
    use Agent
    def start_link(_opts), do: Agent.start_link(fn -> :test_owned end)
  end

  setup_all do
    TrustTopology.ensure_owned!()

    if Process.whereis(@profiles) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles, backend: nil, write_mode: :sync},
          id: @profiles
        )
      )
    end

    assert is_pid(Process.whereis(Security.CapabilityStore))
    :ok
  end

  setup do
    settings =
      Enum.map(@security_settings, fn {key, value} -> {:arbor_security, key, value} end) ++
        [{:arbor_security, :consensus_module, ApprovalProbe}]

    old = Enum.map(settings, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)
    Enum.each(settings, fn {app, key, value} -> Application.put_env(app, key, value) end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "lifecycle-authorization-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    legacy = Application.fetch_env(:arbor_agent, :legacy_agents_dir)
    Application.put_env(:arbor_agent, :legacy_agents_dir, dir)
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity(identity)

    on_exit(fn ->
      _ = Security.deregister_identity(identity.agent_id)
      Enum.each(old, fn {app, key, previous} -> restore_env(app, key, previous) end)
      restore_env(:arbor_agent, :legacy_agents_dir, legacy)
      File.rm_rf!(dir)
    end)

    %{caller: identity.agent_id, identity: identity, dir: dir}
  end

  for operation <- [:create, :stop, :destroy, :restore] do
    test "security regression: pending approval does not perform #{operation}", ctx do
      operation = unquote(operation)
      fixture = fixture(operation, ctx)
      grant(ctx.caller, resource(operation, fixture.target), true)

      {result, effects, decisions} = observe(fn -> invoke(operation, ctx.caller, fixture) end)
      track_created(result)

      assert {:ok, :pending_approval, "lifecycle-pending-fixture"} = result
      assert {:ok, :pending_approval, "lifecycle-pending-fixture"} in decisions
      assert effects == [], "pending approval reached a lifecycle effect: #{inspect(effects)}"
      assert_preserved(operation, fixture)
    end

    test "security regression: unavailable security does not perform #{operation}", ctx do
      operation = unquote(operation)
      fixture = fixture(operation, ctx)
      grant(ctx.caller, resource(operation, fixture.target), false)

      # The shared child remains alive with its original state and supervisor.
      # Hide only its registered name for this synchronous operation, restoring
      # the SAME PID in `after`. Never kill/restart a permanent shared child.
      # Invalid create opts avoid even a partial identity if testing old source;
      # the observed public Lifecycle callback still proves the old bypass.
      fixture = unavailable_fixture(operation, fixture)

      {result, effects, decisions} =
        without_capability_registration(fn ->
          observe(fn -> invoke(operation, ctx.caller, fixture) end)
        end)

      assert {:error, {:unauthorized, :security_unavailable}} = result
      assert decisions == []
      assert effects == [], "unavailable security reached a lifecycle effect: #{inspect(effects)}"
      assert_preserved(operation, fixture)
    end

    test "affirmative authorization permits #{operation}", ctx do
      operation = unquote(operation)
      fixture = fixture(operation, ctx)
      grant(ctx.caller, resource(operation, fixture.target), false)
      {result, effects, decisions} = observe(fn -> invoke(operation, ctx.caller, fixture) end)
      track_created(result)

      assert {:ok, :authorized} in decisions
      assert lifecycle_effect(operation) in effects
      assert_performed(operation, fixture, result)
    end
  end

  test "gateway-preverified signed request is not verified and consumed twice", ctx do
    fixture = fixture(:restore, ctx)
    uri = resource(:restore, fixture.target)
    grant(ctx.caller, uri, false)
    Application.put_env(:arbor_security, :identity_verification, true)
    {:ok, signed} = SignedRequest.sign(uri, ctx.caller, ctx.identity.private_key)
    assert {:ok, caller} = Security.verify_request(signed)
    assert caller == ctx.caller

    {result, effects, _} =
      observe(fn ->
        Agents.authorize_restore(ctx.caller, fixture.target, signed_request: signed)
      end)

    assert {Lifecycle, :restore, 1} in effects
    assert_performed(:restore, fixture, result)
    assert {:error, :replayed_nonce} = Security.verify_request(signed)
  end

  test "security regression: missing signed request remains refused when identity verification is required",
       ctx do
    fixture = fixture(:restore, ctx)
    grant(ctx.caller, resource(:restore, fixture.target), false)
    Application.put_env(:arbor_security, :identity_verification, true)
    {result, effects, _} = observe(fn -> invoke(:restore, ctx.caller, fixture) end)
    assert {:error, {:unauthorized, :missing_signed_request}} = result
    assert effects == []
    assert_preserved(:restore, fixture)
  end

  test "security regression: an ungranted caller cannot delete an existing profile", ctx do
    fixture = fixture(:destroy, ctx)
    {result, effects, _} = observe(fn -> invoke(:destroy, ctx.caller, fixture) end)
    assert {:error, {:unauthorized, _}} = result
    assert effects == []
    assert_preserved(:destroy, fixture)
  end

  test "authorized facade entrypoints remain exported" do
    exports = Agents.__info__(:functions)

    for signature <- [
          {:authorize_spawn, 3},
          {:authorize_action, 3},
          {:authorize_stop, 2},
          {:authorize_create, 2},
          {:authorize_destroy, 2},
          {:authorize_restore, 2},
          {:send_message, 3},
          {:send_message, 4},
          {:dispatch_task, 3},
          {:dispatch_task, 4}
        ] do
      assert signature in exports
    end
  end

  defp fixture(:create, _ctx) do
    target = "lifecycle-create-#{System.unique_integer([:positive])}"

    opts = [
      character: Character.new(name: target),
      capabilities: [],
      initial_goals: [],
      trust_preset: %{"baseline" => "ask", "rules" => %{}},
      memory_opts: [index_enabled: false, auto_embed: false]
    ]

    %{target: target, opts: opts}
  end

  defp fixture(operation, ctx) do
    target = "agent_lifecycle_auth_#{System.unique_integer([:positive])}"

    profile = %Profile{
      agent_id: target,
      display_name: target,
      character: Character.new(name: target),
      created_at: DateTime.utc_now()
    }

    file = Path.join(ctx.dir, target <> ".agent.json")

    if operation == :restore do
      {:ok, json} = Profile.to_json(profile)
      File.write!(file, json)
      assert {:error, :not_found} = Persistence.get(@profiles, BufferedStore, target)
    else
      :ok = Agents.store_profile(profile)
    end

    on_exit(fn -> ProfileStore.delete_profile(target) end)
    fixture = %{target: target, profile: profile, file: file, opts: []}

    if operation == :stop do
      {:ok, pid} =
        Supervisor.start_link([{StubHost, []}],
          strategy: :rest_for_one,
          name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target}}}
        )

      :ok = AgentRegistry.register(target, pid, %{supervisor_pid: pid})

      on_exit(fn ->
        if Process.alive?(pid), do: Supervisor.stop(pid)
        AgentRegistry.unregister(target)
      end)

      Map.put(fixture, :pid, pid)
    else
      fixture
    end
  end

  defp grant(caller, uri, approval?) do
    {:ok, capability} =
      Security.grant(
        principal: caller,
        resource: uri,
        constraints: %{requires_approval: approval?}
      )

    on_exit(fn -> Security.revoke(capability.id) end)
    capability
  end

  defp resource(:stop, target), do: "arbor://agent/stop/" <> target
  defp resource(operation, _target), do: "arbor://agent/lifecycle/" <> Atom.to_string(operation)
  defp unavailable_fixture(:create, fixture), do: %{fixture | opts: []}
  defp unavailable_fixture(_operation, fixture), do: fixture
  defp lifecycle_effect(:create), do: {Lifecycle, :create, 2}
  defp lifecycle_effect(operation), do: {Lifecycle, operation, 1}

  defp invoke(:create, caller, fixture),
    do: Agents.authorize_create(caller, fixture.target, fixture.opts)

  defp invoke(:stop, caller, fixture), do: Agents.authorize_stop(caller, fixture.target)
  defp invoke(:destroy, caller, fixture), do: Agents.authorize_destroy(caller, fixture.target)
  defp invoke(:restore, caller, fixture), do: Agents.authorize_restore(caller, fixture.target)

  defp assert_preserved(:create, fixture) do
    refute Enum.any?(Agents.list_agents(), &(&1.display_name == fixture.target))
  end

  defp assert_preserved(:stop, fixture) do
    assert Process.alive?(fixture.pid)
    assert {:ok, pid} = AgentRegistry.whereis(fixture.target)
    assert pid == fixture.pid
  end

  defp assert_preserved(:destroy, fixture) do
    assert {:ok, profile} = Agents.load_profile(fixture.target)
    assert profile.agent_id == fixture.profile.agent_id
    assert profile.character == fixture.profile.character
  end

  defp assert_preserved(:restore, fixture) do
    assert File.exists?(fixture.file)
    assert {:error, :not_found} = Persistence.get(@profiles, BufferedStore, fixture.target)
  end

  defp assert_performed(:create, fixture, result) do
    assert {:ok, %Profile{} = profile} = result
    assert profile.display_name == fixture.target
    assert profile.auto_start == false
    assert {:ok, persisted} = Agents.load_profile(profile.agent_id)
    assert persisted.agent_id == profile.agent_id
  end

  defp assert_performed(:stop, fixture, result) do
    assert result == :ok
    refute Process.alive?(fixture.pid)
    assert {:error, :not_found} = AgentRegistry.whereis(fixture.target)
  end

  defp assert_performed(:destroy, fixture, result) do
    assert result == :ok
    assert {:error, :not_found} = Agents.load_profile(fixture.target)
  end

  defp assert_performed(:restore, fixture, result) do
    assert {:ok, %Profile{} = profile} = result
    assert profile.agent_id == fixture.target
    assert {:ok, _record} = Persistence.get(@profiles, BufferedStore, fixture.target)
  end

  defp track_created({:ok, %Profile{agent_id: id}}) do
    # Covers the old-source pending-create leak before its assertion fails.
    on_exit(fn -> Agents.destroy_agent(id) end)
  end

  defp track_created(_), do: :ok

  defp without_capability_registration(fun) do
    name = Security.CapabilityStore
    pid = Process.whereis(name)
    assert is_pid(pid) and Process.alive?(pid)
    true = Process.unregister(name)

    result =
      try do
        assert Process.whereis(name) == nil
        fun.()
      after
        true = Process.register(pid, name)
      end

    assert Process.whereis(name) == pid
    result
  end

  defp observe(fun) do
    owner = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run ->
            result =
              try do
                fun.()
              rescue
                error -> {:raised, error.__struct__}
              catch
                kind, _ -> {:caught, kind}
              end

            send(owner, {:observed_result, self(), result})

            receive do
              :release -> :ok
            end
        end
      end)

    session = :trace.session_create(:agent_lifecycle_authorization, self(), [])

    try do
      assert Code.ensure_loaded?(Lifecycle)

      for mfa <- @effects do
        true = :trace.function(session, mfa, true, [:local]) > 0
      end

      true =
        :trace.function(session, {Security, :authorize, 4}, [{:_, [], [{:return_trace}]}], [
          :local
        ]) > 0

      1 = :trace.process(session, worker, true, [:call])
      send(worker, :run)

      result =
        receive do
          {:observed_result, ^worker, result} -> result
        after
          15_000 -> flunk("public lifecycle call did not return")
        end

      barrier = :trace.delivered(session, worker)
      {effects, decisions} = collect_trace(worker, barrier, [], [])
      {result, effects, decisions}
    after
      :trace.session_destroy(session)
      send(worker, :release)

      receive do
        {:DOWN, ^monitor, :process, ^worker, _} -> :ok
      after
        5_000 ->
          Process.exit(worker, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^worker, _} -> :ok
          after
            5_000 -> flunk("test worker did not terminate")
          end
      end
    end
  end

  defp collect_trace(worker, barrier, effects, decisions) do
    receive do
      {:trace, ^worker, :call, {module, name, args}} ->
        mfa = {module, name, length(args)}

        collect_trace(
          worker,
          barrier,
          if(mfa in @effects, do: [mfa | effects], else: effects),
          decisions
        )

      {:trace, ^worker, :return_from, {Security, :authorize, 4}, result} ->
        collect_trace(worker, barrier, effects, [result | decisions])

      {:trace_delivered, ^worker, ^barrier} ->
        {Enum.reverse(effects), Enum.reverse(decisions)}
    after
      5_000 -> flunk("trace delivery barrier did not complete")
    end
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
