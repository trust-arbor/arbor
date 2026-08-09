defmodule Arbor.Agent.Orchestration.TaskControlLeaseSecurityRegressionTest do
  @moduledoc """
  Causal public security regression for automatic exact-task authority after
  Orchestration.dispatch/3.

  This file must compile and run unchanged against the immediate parent and the
  candidate. It must not reference TaskControlLease or any candidate-only API.

  Decisive parent failure: after a dispatch authorized only with
  `arbor://agent/dispatch/<agent>`, `Orchestration.task_status/2` for the
  returned task_id fails with `{:unauthorized, :task_read_required}` on the
  parent (dispatch never minted task-read authority). On the candidate the same
  public call succeeds because dispatch atomically grants the exact-task lease.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Security

  defmodule HangRunner do
    @moduledoc false
    def run(_agent_id, _task, _opts) do
      Process.sleep(60_000)
      {:ok, %{result_type: :test, payload: %{}, raw: "hang"}}
    end
  end

  defmodule FakeInteractionRouter do
    @moduledoc false
    def pending_interactions, do: Process.get({__MODULE__, :pending}, [])

    def respond_to_interaction(id, decision, metadata) do
      send(self(), {:interaction_respond, id, decision, metadata})
      :ok
    end
  end

  defmodule FakeConsensus do
    @moduledoc false
    def list_pending_proposals, do: []
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_agent)

    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    assert Process.whereis(Arbor.Security.CapabilityStore) != nil
    :ok
  end

  setup do
    original_identity = Application.get_env(:arbor_security, :identity_verification, true)
    original_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled, true)
    original_strict = Application.get_env(:arbor_security, :strict_identity_mode, false)
    original_signing = Application.get_env(:arbor_security, :capability_signing_required, true)

    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)

    supervisor_name = unique_name(:lease_sec_supervisor)
    store_name = unique_name(:lease_sec_store)

    supervisor =
      start_supervised!({Task.Supervisor, name: supervisor_name}, id: supervisor_name)

    Arbor.Agent.Orchestration.TaskControlRecoveryMemory.ensure!()
    Arbor.Agent.Orchestration.TaskControlRecoveryMemory.reset!()

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: Arbor.Agent.Orchestration.TaskControlRecoveryMemory},
        id: store_name
      )

    Process.delete({FakeInteractionRouter, :pending})

    on_exit(fn ->
      Application.put_env(:arbor_security, :identity_verification, original_identity)
      Application.put_env(:arbor_security, :reflex_checking_enabled, original_reflex)
      Application.put_env(:arbor_security, :strict_identity_mode, original_strict)
      Application.put_env(:arbor_security, :capability_signing_required, original_signing)
    end)

    %{store: store}
  end

  test "security regression: dispatch omits required caller authority on parent; candidate mints exact-task authority",
       %{store: store} do
    caller = "agent_lease_caller_#{System.unique_integer([:positive])}"
    agent = "agent_lease_target_#{System.unique_integer([:positive])}"

    # Only dispatch authority — no permanent task/read, approval/read, etc.
    assert {:ok, _} =
             Security.grant(
               principal: caller,
               resource: "arbor://agent/dispatch/#{agent}",
               constraints: %{},
               delegation_depth: 0
             )

    # Public dispatch never accepts caller task_id (server-owned ids).
    assert {:error, :caller_selected_task_id_rejected} =
             Orchestration.dispatch(agent, "work a",
               caller_id: caller,
               task_id: "task_should_reject",
               task_store: TaskStore,
               runner: HangRunner,
               name: store
             )

    assert {:ok, task_a} =
             Orchestration.dispatch(agent, "work a",
               caller_id: caller,
               task_store: TaskStore,
               runner: HangRunner,
               name: store
             )

    assert is_binary(task_a)

    # DECISIVE PUBLIC ASSERTION (parent fails here; candidate passes):
    # task_status is a pre-existing public Orchestration operation. On the
    # parent, dispatch never granted task-read, so this fails closed. On the
    # candidate, the atomic lease includes exact task-read.
    assert {:ok, status} =
             Orchestration.task_status(task_a, caller_id: caller, name: store)

    assert status.task_id == task_a
    refute Map.has_key?(status, :task_control_lease)
    refute Map.has_key?(status, :approval_answer_cap_id)

    # Causal public path: task A result is authorized by the automatic lease
    # (not_ready while running, or ok when finished) without lease/cap leakage.
    case Orchestration.task_result(task_a, caller_id: caller, name: store) do
      {:error, :not_ready} ->
        :ok

      {:ok, result} when is_map(result) ->
        refute Map.has_key?(result, :task_control_lease)
        refute Map.has_key?(result, :approval_answer_cap_id)

      other ->
        flunk("unexpected task_result for leased task A: #{inspect(other)}")
    end

    # Sibling task B without caller lease for B.
    task_b = "task_lease_b_#{System.unique_integer([:positive])}"

    assert {:ok, ^task_b} =
             TaskStore.dispatch(agent, "work b",
               name: store,
               task_id: task_b,
               runner: HangRunner
             )

    # Prefix-like sibling shares a string prefix with task A but must not inherit
    # task-A authority (exact-task scope only).
    prefix_like = task_a <> "x"

    assert {:ok, ^prefix_like} =
             TaskStore.dispatch(agent, "work prefix",
               name: store,
               task_id: prefix_like,
               runner: HangRunner
             )

    assert {:error, {:unauthorized, :task_read_required}} =
             Orchestration.task_status(task_b, caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_read_required}} =
             Orchestration.task_result(task_b, caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_steer_required}} =
             Orchestration.steer_task(task_b, "nope", caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_cancel_required}} =
             Orchestration.cancel_task(task_b, caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_adoption_required}} =
             Orchestration.adopt_task_change(task_b, "main", caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_read_required}} =
             Orchestration.task_status(prefix_like, caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_read_required}} =
             Orchestration.task_result(prefix_like, caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_steer_required}} =
             Orchestration.steer_task(prefix_like, "nope", caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_cancel_required}} =
             Orchestration.cancel_task(prefix_like, caller_id: caller, name: store)

    assert {:error, {:unauthorized, :task_adoption_required}} =
             Orchestration.adopt_task_change(prefix_like, "main", caller_id: caller, name: store)

    assert {:error, :invalid_task_id} =
             Orchestration.task_status(task_a <> "/evil", caller_id: caller, name: store)

    assert {:error, :invalid_task_id} =
             Orchestration.task_status(task_a <> "*", caller_id: caller, name: store)

    # Behavioral list filter: task-A, task-B, and prefix-like pending approvals.
    irq_a = "irq_a_#{System.unique_integer([:positive])}"
    irq_b = "irq_b_#{System.unique_integer([:positive])}"
    irq_prefix = "irq_prefix_#{System.unique_integer([:positive])}"
    irq_bad = "irq_bad_#{System.unique_integer([:positive])}"

    Process.put(
      {FakeInteractionRouter, :pending},
      [
        interaction_request(irq_a, agent, caller, "arbor://shell/exec",
          metadata: %{principal_id: agent, task_id: task_a}
        ),
        interaction_request(irq_b, agent, caller, "arbor://shell/exec",
          metadata: %{principal_id: agent, task_id: task_b}
        ),
        interaction_request(irq_prefix, agent, caller, "arbor://shell/exec",
          metadata: %{principal_id: agent, task_id: prefix_like}
        ),
        interaction_request(irq_bad, agent, caller, "arbor://shell/exec",
          metadata: %{principal_id: agent, task_id: task_a <> "/**"}
        )
      ]
    )

    assert {:ok, listed} =
             Orchestration.list_pending_approvals(
               caller_id: caller,
               task_id: task_a,
               interaction_router: FakeInteractionRouter,
               consensus_module: FakeConsensus
             )

    listed_ids = Enum.map(listed, & &1.id)
    assert irq_a in listed_ids
    refute irq_b in listed_ids
    refute irq_prefix in listed_ids
    refute irq_bad in listed_ids

    # Prefix-like task filter must not inherit task-A approval-read authority.
    assert {:error, {:unauthorized, _}} =
             Orchestration.list_pending_approvals(
               caller_id: caller,
               task_id: prefix_like,
               interaction_router: FakeInteractionRouter,
               consensus_module: FakeConsensus
             )

    # Unfiltered list still requires global approval-read (not held).
    assert {:error, {:unauthorized, _}} =
             Orchestration.list_pending_approvals(
               caller_id: caller,
               interaction_router: FakeInteractionRouter,
               consensus_module: FakeConsensus
             )

    # Public answer_approval with real pending records.
    assert :ok =
             Orchestration.answer_approval(irq_a, :approve,
               caller_id: caller,
               interaction_router: FakeInteractionRouter,
               consensus_module: FakeConsensus
             )

    assert {:error, {:unauthorized, :approval_answer_required}} =
             Orchestration.answer_approval(irq_b, :approve,
               caller_id: caller,
               interaction_router: FakeInteractionRouter,
               consensus_module: FakeConsensus
             )

    assert {:error, {:unauthorized, :approval_answer_required}} =
             Orchestration.answer_approval(irq_prefix, :approve,
               caller_id: caller,
               interaction_router: FakeInteractionRouter,
               consensus_module: FakeConsensus
             )

    assert {:error, {:unauthorized, :approval_answer_required}} =
             Orchestration.answer_approval(irq_bad, :approve,
               caller_id: caller,
               interaction_router: FakeInteractionRouter,
               consensus_module: FakeConsensus
             )

    # Exact-task cancel also works with the automatic lease on the candidate.
    assert {:ok, %{state: :cancelled}} =
             Orchestration.cancel_task(task_a, caller_id: caller, name: store)
  end

  defp interaction_request(id, agent_id, user_id, resource_uri, opts) do
    metadata = Keyword.get(opts, :metadata, %{principal_id: agent_id})

    %{
      request_id: id,
      kind: :approval,
      agent_id: agent_id,
      user_id: user_id,
      description: "Authorization request for #{resource_uri}",
      resource_uri: resource_uri,
      metadata: metadata,
      submitted_at: DateTime.utc_now()
    }
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
