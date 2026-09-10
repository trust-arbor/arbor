Code.require_file(
  "../../../../arbor_actions/test/support/scheduler_transport_fixture.exs",
  __DIR__
)

defmodule Arbor.Orchestrator.SchedulerToolTransportSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Reports.BuildMorningDigest
  alias Arbor.Actions.Scheduler.{CancelRoutine, EnqueueRoutine, ListRoutines}
  alias Arbor.Actions.SchedulerTransportFixture, as: Fixture
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression

  setup do
    fixture = Fixture.start!()
    :erlang.trace_pattern({Actions, :authorize_and_execute, 4}, true, [])
    on_exit(fn -> :erlang.trace_pattern({Actions, :authorize_and_execute, 4}, false, []) end)
    fixture
  end

  test "security regression: enqueue tool signs the complete intent as its actual execution principal",
       fixture do
    assert_tool_transport(fixture, :enqueue, EnqueueRoutine, "scheduler_enqueue_routine")
    assert_receive {:routine_prepared, principal}
    assert principal == fixture.owner.identity.agent_id
  end

  test "security regression: list tool signs the exact pagination as its actual execution principal",
       fixture do
    assert_tool_transport(fixture, :list, ListRoutines, "scheduler_list_routines")
  end

  test "security regression: cancel tool signs the exact job as its actual execution principal",
       fixture do
    assert_tool_transport(fixture, :cancel, CancelRoutine, "scheduler_cancel_routine")
  end

  test "security regression: authority for another principal cannot schedule under an owner's scalar id",
       fixture do
    for {operation, tool} <- tools() do
      assert {:error, _} =
               ActionsExecutor.execute_structured(tool, json_params(operation), ".",
                 agent_id: fixture.owner.identity.agent_id,
                 signing_authority: fixture.other.authority
               )
    end

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: model arguments cannot supply or smuggle either scheduler proof",
       fixture do
    for {operation, tool} <- tools(),
        claim <- [
          %{"routine_request" => %{"owner_id" => fixture.owner.identity.agent_id}},
          %{"metadata" => %{"routineEffectToken" => %{"lease" => "caller", "token" => "caller"}}}
        ] do
      assert {:error, reason} =
               ActionsExecutor.execute_structured(
                 tool,
                 Map.merge(json_params(operation), claim),
                 ".",
                 opts(fixture)
               )

      assert reason =~ "caller_supplied_signing_credentials"
    end

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: scalar owner or legacy action signer is not a scheduler operation proof",
       fixture do
    for {operation, tool} <- tools() do
      for credentials <- [
            [],
            [
              signer:
                Security.make_signer(
                  fixture.owner.identity.agent_id,
                  fixture.owner.identity.private_key
                )
            ]
          ] do
        assert {:error, _} =
                 ActionsExecutor.execute_structured(
                   tool,
                   json_params(operation),
                   ".",
                   [agent_id: fixture.owner.identity.agent_id] ++ credentials
                 )
      end
    end

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: executor preserves private-turn scheduling denial and agent-only list ownership",
       fixture do
    for {operation, tool} <- [
          {:enqueue, "scheduler_enqueue_routine"},
          {:cancel, "scheduler_cancel_routine"}
        ] do
      assert {:error, reason} =
               ActionsExecutor.execute_structured(
                 tool,
                 json_params(operation),
                 ".",
                 opts(fixture, memory_write_policy: :deny)
               )

      assert reason =~ "private_turn_memory_write_denied"
    end

    refute_received {:routine_accepted, _, _, _, _}

    assert {:ok, result} =
             ActionsExecutor.execute_structured(
               "scheduler_list_routines",
               json_params(:list),
               ".",
               opts(fixture,
                 memory_write_policy: :deny,
                 author_id: "human_attribution_is_not_authority"
               )
             )

    assert result.owner_id == fixture.owner.identity.agent_id
    refute Map.has_key?(result, :human_id)
    assert_receive {:routine_accepted, :list, _, proof, principal}
    assert proof.agent_id == principal
    assert principal == fixture.owner.identity.agent_id
  end

  test "security regression: source effect token reaches only the digest and no signer reaches its action context",
       fixture do
    token = %{
      lease: "lease_" <> Base.url_encode64(:binary.copy(<<41>>, 18), padding: false),
      token: Base.url_encode64(:binary.copy(<<42>>, 32), padding: false)
    }

    params = %{
      "reports_directory" => "reports",
      "topics" => ["upstream-deps", "upstream-deps-summary"]
    }

    {result, context} =
      traced_execute(
        "reports_build_morning_digest",
        BuildMorningDigest,
        params,
        opts(fixture, routine_effect_token: token)
      )

    assert {:error, reason} = result
    assert reason =~ "test_effect_boundary_stop"
    assert context.routine_effect_token == token
    assert_no_signer(context)
    assert_receive {:routine_effect, ^token, %{operation: :enter, principal: principal}}
    assert principal == fixture.owner.identity.agent_id

    {result, list_context} =
      traced_execute(
        "scheduler_list_routines",
        ListRoutines,
        json_params(:list),
        opts(fixture, routine_effect_token: token)
      )

    assert {:ok, _} = result
    refute Map.has_key?(list_context, :routine_effect_token)
  end

  test "security regression: a required effect token cannot be dropped at the executor boundary",
       fixture do
    params = %{
      "reports_directory" => "reports",
      "topics" => ["upstream-deps", "upstream-deps-summary"]
    }

    assert {:error, reason} =
             ActionsExecutor.execute_structured(
               "reports_build_morning_digest",
               params,
               ".",
               opts(fixture)
             )

    assert reason =~ "routine_effect_token_required"
    refute_received {:routine_effect, _, _}
  end

  defp assert_tool_transport(fixture, operation, module, tool) do
    {result, context} =
      traced_execute(
        tool,
        module,
        json_params(operation),
        opts(fixture, author_id: fixture.other.identity.agent_id)
      )

    assert {:ok, _} = result
    assert_receive {:routine_accepted, ^operation, value, proof, principal}
    assert principal == fixture.owner.identity.agent_id
    assert %SignedRequest{} = proof
    assert proof.agent_id == principal
    assert {:ok, expected} = Arbor.Scheduler.routine_request_payload(operation, value)
    assert proof.payload == expected

    assert :ok =
             Security.verify_detached(
               SignedRequest.signing_payload(proof),
               proof.signature,
               fixture.owner.identity.public_key
             )

    assert context.routine_request == %{operation: operation, value: value, proof: proof}
    refute context.signed_request.payload == proof.payload
    refute Map.has_key?(context, :routine_effect_token)
    refute Map.has_key?(context, :human_id)
    refute Map.has_key?(context, :session_token)
    assert_no_signer(context)
  end

  defp traced_execute(tool, module, params, opts) do
    observer = self()

    result =
      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, observer}])
        ActionsExecutor.execute_structured(tool, params, ".", opts)
      end)
      |> Task.await()

    assert_receive {:trace, _, :call,
                    {Actions, :authorize_and_execute, [_, ^module, _, context]}},
                   1_000

    {result, context}
  end

  defp assert_no_signer(context) do
    refute Map.has_key?(context, :signing_authority)
    refute Map.has_key?(context, :signer)
    assert context.auth_context.signer == nil
    nested = Map.get(context, :nested_engine_opts) || []
    refute Keyword.has_key?(nested, :signing_authority)
    refute Keyword.has_key?(nested, :signer)
    refute Keyword.has_key?(nested, :authorizer)
  end

  defp opts(fixture, extra \\ []),
    do:
      [
        agent_id: fixture.owner.identity.agent_id,
        signing_authority: fixture.owner.authority,
        taint: :trusted
      ] ++
        extra

  defp json_params(operation),
    do: Map.new(Fixture.params(operation), fn {key, value} -> {Atom.to_string(key), value} end)

  defp tools,
    do: [
      {:enqueue, "scheduler_enqueue_routine"},
      {:list, "scheduler_list_routines"},
      {:cancel, "scheduler_cancel_routine"}
    ]
end
