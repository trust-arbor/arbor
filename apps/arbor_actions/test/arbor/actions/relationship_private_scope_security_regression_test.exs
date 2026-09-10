defmodule Arbor.Actions.RelationshipPrivateScopeSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Relationship.{Browse, Get, Moment, Save, Summarize}
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression
  @timeout 5_000

  setup do
    for app <- [:arbor_security, :arbor_trust],
        key <- [:policy_enforcer_enabled, :approval_guard_enabled] do
      previous = Application.fetch_env(app, key)
      Application.put_env(app, key, false)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end)
    end

    assert {:ok, identity} = Identity.generate()
    assert :ok = Security.register_identity(identity)

    on_exit(fn ->
      {:ok, caps} = Security.list_capabilities(identity.agent_id)
      Enum.each(caps, &Security.revoke(&1.id))
      Security.deregister_identity(identity.agent_id)
    end)

    %{agent_id: identity.agent_id}
  end

  test "relationship tools use the existing Memory capability family without persistence grants",
       ctx do
    refute Enum.any?(
             [Get, Browse, Summarize, Save, Moment],
             &(&1 in Actions.tool_modules_for_agent(ctx.agent_id))
           )

    for operation <- ["read", "write"],
        do: grant!(ctx.agent_id, "arbor://memory/" <> operation)

    exposed = Actions.tool_modules_for_agent(ctx.agent_id)
    assert Enum.all?([Get, Browse, Summarize, Save, Moment], &(&1 in exposed))
    assert {:ok, caps} = Security.list_capabilities(ctx.agent_id)
    refute Enum.any?(caps, &String.starts_with?(&1.resource_uri, "arbor://persistence/"))
  end

  test "security regression: all legacy relationship read aliases are denied before their first effect",
       ctx do
    grant!(ctx.agent_id, "arbor://memory/read")
    grant!(ctx.agent_id, "arbor://persistence/read")
    context = %{agent_id: ctx.agent_id, memory_write_policy: :deny, taint_policy: :permissive}

    specs =
      for name <- [
            "relationship.get",
            "relationship_get",
            "relationship.browse",
            "relationship_browse",
            "relationship.summarize",
            "relationship_summarize"
          ],
          do: %{
            "type" => name,
            "params" => %{"name" => "Unknown", "memory_write_policy" => "allow"}
          }

    {results, calls} =
      observe_calls(
        fn ->
          Actions.execute_batch(specs, agent_id: ctx.agent_id, context: context)
        end,
        [{Get, :run, 2}, {Browse, :run, 2}, {Summarize, :run, 2}]
      )

    assert Enum.map(results, &elem(&1, 1)) ==
             List.duplicate({:error, :private_turn_relationship_read_denied}, 6)

    assert calls == []

    for policy <- [:absent, nil] do
      control = Map.delete(context, :memory_write_policy)
      control = if policy == nil, do: Map.put(control, :memory_write_policy, nil), else: control

      {_result, calls} =
        observe_calls(
          fn ->
            Actions.authorize_and_execute(ctx.agent_id, Get, %{name: "Unknown"}, control)
          end,
          [{Get, :run, 2}]
        )

      assert Enum.any?(calls, fn {module, function, _args} ->
               module == Get and function == :run
             end)
    end
  end

  test "security regression: a self-scoped block defeats a held parent relationship capability",
       ctx do
    for module <- [Arbor.Trust.EventStore, Arbor.Trust.Store],
        Process.whereis(module) == nil,
        do: start_supervised!({module, []})

    if Process.whereis(Arbor.Trust.Manager) == nil,
      do:
        start_supervised!(
          {Arbor.Trust.Manager, circuit_breaker: false, decay: false, event_store: true}
        )

    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
    assert {:ok, _} = Arbor.Trust.create_trust_profile(ctx.agent_id)

    assert {:ok, _} =
             Arbor.Trust.Store.update_profile(ctx.agent_id, fn profile ->
               %{
                 profile
                 | baseline: :ask,
                   rules: %{
                     "arbor://memory/read" => :auto,
                     ("arbor://memory/read/" <> ctx.agent_id) => :block
                   }
               }
             end)

    grant!(ctx.agent_id, "arbor://memory/read")
    grant!(ctx.agent_id, "arbor://persistence/read")

    {result, calls} =
      observe_calls(
        fn ->
          Actions.authorize_and_execute(ctx.agent_id, Get, %{name: "Unknown"}, %{
            agent_id: ctx.agent_id
          })
        end,
        [{Get, :run, 2}]
      )

    assert result == {:error, :unauthorized}
    assert calls == []
  end

  defp grant!(agent_id, resource) do
    assert {:ok, _} = Security.grant(principal: agent_id, resource: resource)
  end

  defp observe_calls(fun, mfas) do
    Enum.each(mfas, fn {module, _function, _arity} -> Code.ensure_loaded!(module) end)
    session = :trace.session_create(__MODULE__, self(), [])
    run_ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          {:run, ^run_ref} ->
            try do
              fun.()
            rescue
              exception ->
                {:observed_action_exception, exception.__struct__, Exception.message(exception)}
            end
        end
      end)

    try do
      for mfa <- mfas do
        assert 1 = :trace.function(session, mfa, true, [:local])
      end

      assert 1 = :trace.process(session, task.pid, true, [:call])
      send(task.pid, {:run, run_ref})
      result = Task.await(task, @timeout)
      delivered = :trace.delivered(session, :all)
      assert_receive {:trace_delivered, :all, ^delivered}, @timeout
      {result, drain_calls(task.pid, [])}
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      :trace.session_destroy(session)
    end
  end

  defp drain_calls(pid, calls) do
    receive do
      {:trace, ^pid, :call, call} -> drain_calls(pid, [call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
