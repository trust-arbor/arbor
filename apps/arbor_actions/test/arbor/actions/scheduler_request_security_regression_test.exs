Code.require_file("../../support/scheduler_transport_fixture.exs", __DIR__)

defmodule Arbor.Actions.SchedulerRequestSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Scheduler.{CancelRoutine, EnqueueRoutine, ListRoutines}
  alias Arbor.Actions.SchedulerTransportFixture, as: Fixture
  alias Arbor.Contracts.Security.SignedRequest

  @moduletag :fast
  @moduletag :security_regression
  @operations [{:enqueue, EnqueueRoutine}, {:list, ListRoutines}, {:cancel, CancelRoutine}]

  setup do
    Fixture.start!()
  end

  test "all three public actions carry an independently signed exact operation", %{owner: owner} do
    for {operation, module} <- @operations do
      params = Fixture.params(operation)
      request = Fixture.request!(owner, module, params)
      context = Fixture.context!(owner, module, params, %{routine_request: request})

      assert {:ok, result} =
               Actions.authorize_and_execute(owner.identity.agent_id, module, params, context)

      assert_receive {:routine_accepted, ^operation, value, proof, principal}
      assert principal == owner.identity.agent_id
      assert value == request.value
      assert proof == request.proof
      refute proof.payload == context.signed_request.payload
      refute Map.has_key?(result, :human_id)
      if is_map(value), do: refute(Map.has_key?(value, "human_id"))
    end
  end

  test "security regression: raw owner claims and direct run cannot create action authority", %{
    owner: owner
  } do
    for {operation, module} <- @operations do
      params = Fixture.params(operation)
      request = Fixture.request!(owner, module, params)

      claims = %{
        agent_id: owner.identity.agent_id,
        owner_id: owner.identity.agent_id,
        human_id: "human_claim",
        routine_request: request
      }

      assert {:error, _} = module.run(params, claims)

      assert {:error, _} =
               Actions.authorize_and_execute(owner.identity.agent_id, module, params, claims)

      assert {:error, :routine_request_proof_required} =
               Actions.authorize_and_execute(
                 owner.identity.agent_id,
                 module,
                 params,
                 Fixture.context!(owner, module, params)
               )
    end

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: another valid action principal cannot use the owner's proof", %{
    owner: owner,
    other: other
  } do
    for {operation, module} <- @operations do
      params = Fixture.params(operation)
      request = Fixture.request!(owner, module, params)
      context = Fixture.context!(other, module, params, %{routine_request: request})

      assert {:error, :routine_request_proof_required} =
               Actions.authorize_and_execute(other.identity.agent_id, module, params, context)
    end

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: changed parameters cannot reuse a prepared request", %{owner: owner} do
    changes = [
      {:enqueue, EnqueueRoutine,
       %{Fixture.params(:enqueue) | request_id: "changed_request_0001"}},
      {:list, ListRoutines, %{limit: 8, before_id: 91}},
      {:cancel, CancelRoutine, %{job_id: 74}}
    ]

    for {operation, module, changed} <- changes do
      request = Fixture.request!(owner, module, Fixture.params(operation))
      context = Fixture.context!(owner, module, changed, %{routine_request: request})

      assert {:error, :routine_request_proof_required} =
               Actions.authorize_and_execute(owner.identity.agent_id, module, changed, context)
    end

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: signed payload, signature and operation cannot be substituted", %{
    owner: owner
  } do
    params = Fixture.params(:cancel)
    request = Fixture.request!(owner, CancelRoutine, params)
    {:ok, different_payload} = Arbor.Scheduler.routine_request_payload(:cancel, 74)

    {:ok, list_payload} =
      Arbor.Scheduler.routine_request_payload(:list, %{"limit" => 20, "before_id" => nil})

    {:ok, wrong_operation_proof} =
      SignedRequest.sign(list_payload, owner.identity.agent_id, owner.identity.private_key)

    for changed <- [
          %{request | proof: %{request.proof | payload: different_payload}},
          %{request | proof: %{request.proof | signature: :binary.copy(<<0>>, 64)}},
          %{request | proof: wrong_operation_proof},
          %{request | operation: :list},
          %{request | proof: %{agent_id: owner.identity.agent_id}}
        ] do
      context = Fixture.context!(owner, CancelRoutine, params, %{routine_request: changed})

      assert {:error, _} =
               Actions.authorize_and_execute(
                 owner.identity.agent_id,
                 CancelRoutine,
                 params,
                 context
               )
    end

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: a consumed operation proof cannot be replayed with fresh action authentication",
       %{owner: owner} do
    params = Fixture.params(:list)
    request = Fixture.request!(owner, ListRoutines, params)
    context = Fixture.context!(owner, ListRoutines, params, %{routine_request: request})

    assert {:ok, _} =
             Actions.authorize_and_execute(owner.identity.agent_id, ListRoutines, params, context)

    assert_receive {:routine_accepted, :list, _, _, _}

    fresh_context = Fixture.context!(owner, ListRoutines, params, %{routine_request: request})

    assert {:error, :routine_authentication_failed} =
             Actions.authorize_and_execute(
               owner.identity.agent_id,
               ListRoutines,
               params,
               fresh_context
             )

    refute_received {:routine_accepted, _, _, _, _}
  end

  test "security regression: private-turn restriction denies scheduling and cancellation before the peer",
       %{owner: owner} do
    for {operation, module} <- [{:enqueue, EnqueueRoutine}, {:cancel, CancelRoutine}] do
      params = Fixture.params(operation)
      request = Fixture.request!(owner, module, params)

      context =
        Fixture.context!(owner, module, params, %{
          routine_request: request,
          memory_write_policy: :deny
        })

      assert {:error, :private_turn_memory_write_denied} =
               Actions.authorize_and_execute(owner.identity.agent_id, module, params, context)
    end

    refute_received {:routine_accepted, _, _, _, _}

    params = Fixture.params(:list)
    request = Fixture.request!(owner, ListRoutines, params)

    context =
      Fixture.context!(owner, ListRoutines, params, %{
        routine_request: request,
        memory_write_policy: :deny
      })

    assert {:ok, _} =
             Actions.authorize_and_execute(owner.identity.agent_id, ListRoutines, params, context)

    assert_receive {:routine_accepted, :list, _, _, principal}
    assert principal == owner.identity.agent_id
  end
end
