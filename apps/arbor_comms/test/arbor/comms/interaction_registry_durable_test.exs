defmodule Arbor.Comms.InteractionRegistryDurableTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRegistry.Authority
  alias Arbor.Comms.InteractionRegistry.DurableLifecycleCore
  alias Arbor.Comms.InteractionRegistry.DurableStore
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Comms.PresenceTracker
  alias Arbor.Contracts.Comms.Interaction
  alias Arbor.Contracts.Persistence.Record
  alias __MODULE__.Backend
  alias __MODULE__.ProcessLifetimeBackend

  @moduletag :fast

  defmodule TestAdapter do
    @behaviour Arbor.Contracts.Comms.ChannelAdapter

    def send_interaction(channel_meta, %Interaction{} = interaction) do
      send(Map.fetch!(channel_meta, :test_pid), {:durable_adapter_called, interaction})
      :ok
    end

    def parse_response(_raw), do: :not_interaction
    def channel_kind, do: :dashboard
  end

  setup do
    path =
      Path.join(System.tmp_dir!(), "arbor-comms-durable-#{System.unique_integer([:positive])}")

    Backend.start_link(path)
    original = Application.get_env(:arbor_comms, :durable_interaction_store)

    Application.put_env(
      :arbor_comms,
      :durable_interaction_store,
      backend: Backend,
      namespace: :durable_interaction_integration_test,
      opts: [path: path],
      max_data_bytes: 65_536,
      max_items: 32
    )

    restart_authority()
    InteractionRegistry.reset()

    on_exit(fn ->
      restore_config(original)
      restart_authority()
      Backend.stop()
      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "the facade exposes durable readiness and rejects unsupported durability" do
    assert {:ok, %{durability: :node_restart}} = Arbor.Comms.durable_readiness()
    assert Arbor.Comms.durable_ready?()

    assert {:ok, "irq_facade_durable"} =
             Arbor.Comms.request_interaction(
               interaction_attrs("facade", request_id: "irq_facade_durable"),
               durability: :node_restart
             )

    assert {:error, :unsupported_durability} =
             InteractionRouter.request(
               interaction_attrs("unsupported", request_id: "irq_unsupported"),
               durability: :process_lifetime
             )

    assert {:error, :unsupported_durability} =
             InteractionRegistry.put(
               build_interaction(
                 interaction_attrs("unsupported direct", request_id: "irq_direct")
               ),
               durability: :process_lifetime
             )
  end

  test "durable admission is idempotent and rejects a different interaction" do
    attrs = interaction_attrs("duplicate", request_id: "irq_durable_duplicate")
    interaction = build_interaction(attrs)

    assert {:ok, request_id} =
             InteractionRouter.request(interaction, durability: :node_restart)

    assert {:ok, :existing, %Interaction{request_id: ^request_id}} =
             InteractionRegistry.admit(interaction, durability: :node_restart)

    assert {:ok, ^request_id} =
             InteractionRouter.request(interaction, durability: :node_restart)

    assert {:error, :already_tracked} =
             InteractionRouter.request(%{attrs | description: "different"},
               durability: :node_restart
             )
  end

  test "security regression: generated submission time does not change admission identity" do
    user_id = "generated_retry_user_#{System.unique_integer([:positive])}"
    track_dashboard(user_id)

    attrs =
      interaction_attrs("deterministic design checkpoint",
        request_id: "irq_generated_submission_retry",
        user_id: user_id,
        metadata: %{
          "task_id" => "task_generated_retry",
          "evidence" => %{"digest" => "sha256:exact"}
        },
        resource_uri: "arbor://action/coding/design_checkpoint",
        expires_at: ~U[2030-01-01 00:00:00Z]
      )
      |> Map.delete(:submitted_at)

    first = build_interaction(attrs)
    Process.sleep(2)
    second = build_interaction(attrs)
    refute first.submitted_at == second.submitted_at

    opts = [durability: :node_restart, adapter_map: %{dashboard: TestAdapter}]

    assert {:ok, first.request_id} == InteractionRouter.request(first, opts)
    assert_receive {:durable_adapter_called, %Interaction{request_id: first_id}}
    assert first_id == first.request_id

    assert {:ok, second.request_id} == InteractionRouter.request(second, opts)
    refute_receive {:durable_adapter_called, _interaction}, 100

    InteractionRegistry.reset()

    assert {:ok, :existing, %Interaction{request_id: "irq_generated_submission_retry"}} =
             InteractionRegistry.admit(second, durability: :node_restart)

    changed_evidence = put_in(second.metadata["evidence"]["digest"], "sha256:different")

    assert {:error, :already_tracked} =
             InteractionRegistry.admit(changed_evidence, durability: :node_restart)

    refute_receive {:durable_adapter_called, _interaction}, 100
  end

  test "security regression: volatile to durable admission cannot rebind an existing ID" do
    interaction =
      build_interaction(
        interaction_attrs("volatile owner", request_id: "irq_volatile_to_durable")
      )

    assert {:ok, interaction.request_id} ==
             InteractionRouter.request(interaction, adapter_map: %{})

    assert {:error, :already_tracked} =
             InteractionRouter.request(interaction,
               durability: :node_restart,
               adapter_map: %{}
             )

    assert {:error, :already_tracked} =
             InteractionRouter.request(%{interaction | description: "changed volatile payload"},
               adapter_map: %{}
             )

    assert {:ok, ^interaction} = InteractionRegistry.get(interaction.request_id)
    assert {:error, :not_found} = DurableStore.get(interaction.request_id)

    assert %{durability: :volatile} =
             :sys.get_state(Authority).entries[interaction.request_id]
  end

  test "security regression: durable to volatile and changed payload retries cannot rebind" do
    interaction =
      build_interaction(interaction_attrs("durable owner", request_id: "irq_durable_to_volatile"))

    assert {:ok, interaction.request_id} ==
             InteractionRouter.request(interaction,
               durability: :node_restart,
               adapter_map: %{}
             )

    {:ok, record_before} = DurableStore.get(interaction.request_id)

    assert {:error, :already_tracked} =
             InteractionRouter.request(interaction, adapter_map: %{})

    assert {:error, :already_tracked} =
             InteractionRouter.request(%{interaction | description: "changed durable payload"},
               durability: :node_restart,
               adapter_map: %{}
             )

    assert {:ok, ^record_before} = DurableStore.get(interaction.request_id)

    assert %{durability: :node_restart, operation_id: operation_id} =
             :sys.get_state(Authority).entries[interaction.request_id]

    assert operation_id == record_before.data["operation_id"]
  end

  test "security regression: identical pending retry does not dispatch a second notification" do
    user_id = "durable_retry_user_#{System.unique_integer([:positive])}"
    track_dashboard(user_id)

    interaction =
      build_interaction(
        interaction_attrs("notify once",
          request_id: "irq_durable_notify_once",
          user_id: user_id
        )
      )

    opts = [durability: :node_restart, adapter_map: %{dashboard: TestAdapter}]

    assert {:ok, interaction.request_id} == InteractionRouter.request(interaction, opts)
    assert_receive {:durable_adapter_called, %Interaction{request_id: "irq_durable_notify_once"}}

    assert {:ok, interaction.request_id} == InteractionRouter.request(interaction, opts)
    refute_receive {:durable_adapter_called, _interaction}, 100
  end

  test "security regression: tracker mirror failure preserves one dispatch-eligible retry" do
    user_id = "mirror_retry_user_#{System.unique_integer([:positive])}"
    track_dashboard(user_id)

    interaction =
      build_interaction(
        interaction_attrs("mirror retry",
          request_id: "irq_tracker_mirror_retry",
          user_id: user_id
        )
      )

    opts = [durability: :node_restart, adapter_map: %{dashboard: TestAdapter}]
    original_tracker = :sys.get_state(Authority).tracker

    :sys.replace_state(Authority, fn state ->
      %{state | tracker: __MODULE__.UnavailableInteractionTracker}
    end)

    assert {:error, :tracker_unavailable} = InteractionRouter.request(interaction, opts)
    refute_receive {:durable_adapter_called, _interaction}, 100
    assert {:ok, %Record{}} = DurableStore.get(interaction.request_id)

    assert %{admission_state: :persisted_unmirrored} =
             :sys.get_state(Authority).entries[interaction.request_id]

    :sys.replace_state(Authority, fn state -> %{state | tracker: original_tracker} end)

    assert {:ok, interaction.request_id} == InteractionRouter.request(interaction, opts)
    assert_receive {:durable_adapter_called, %Interaction{request_id: "irq_tracker_mirror_retry"}}

    assert %{admission_state: :admitted} =
             :sys.get_state(Authority).entries[interaction.request_id]

    assert {:ok, interaction.request_id} == InteractionRouter.request(interaction, opts)
    refute_receive {:durable_adapter_called, _interaction}, 100
  end

  test "security regression: durable terminal tombstone rejects re-admission without adapter dispatch" do
    user_id = "durable_terminal_user_#{System.unique_integer([:positive])}"
    track_dashboard(user_id)

    interaction =
      build_interaction(
        interaction_attrs("terminal tombstone",
          request_id: "irq_durable_terminal_tombstone",
          user_id: user_id
        )
      )

    opts = [durability: :node_restart, adapter_map: %{dashboard: TestAdapter}]

    assert {:ok, interaction.request_id} == InteractionRouter.request(interaction, opts)
    assert_receive {:durable_adapter_called, %Interaction{request_id: interaction_id}}
    assert interaction_id == interaction.request_id
    assert :ok = InteractionRouter.respond(interaction.request_id, :approved)
    assert {:ok, terminal_record} = DurableStore.get(interaction.request_id)

    assert {:error, {:already_terminal, :responded}} =
             InteractionRouter.request(interaction, opts)

    assert {:error, {:already_terminal, :responded}} =
             InteractionRouter.request(%{interaction | description: "changed tombstone payload"},
               adapter_map: %{dashboard: TestAdapter}
             )

    refute_receive {:durable_adapter_called, _interaction}, 100
    assert {:ok, ^terminal_record} = DurableStore.get(interaction.request_id)
  end

  test "security regression: malformed hydration cannot report durable readiness", %{path: path} do
    request_id = "irq_malformed_hydration"
    malformed_record = Record.new(request_id, %{"unexpected" => true})
    :ok = Backend.put_raw(request_id, malformed_record, path)

    restart_authority()

    assert {:error, :malformed_record} = Arbor.Comms.durable_readiness()
    refute Arbor.Comms.durable_ready?()

    assert {:ok, "irq_volatile_after_bad_hydration"} =
             Arbor.Comms.request_interaction(
               interaction_attrs("volatile remains available",
                 request_id: "irq_volatile_after_bad_hydration"
               ),
               adapter_map: %{}
             )

    assert {:error, :durable_unavailable} =
             Arbor.Comms.request_interaction(
               interaction_attrs("durable fails closed",
                 request_id: "irq_durable_after_bad_hydration"
               ),
               durability: :node_restart,
               adapter_map: %{}
             )
  end

  test "security regression: exact durable waiter returns response persisted before authority restart" do
    request_id = "irq_durable_missed_broadcast"

    interaction =
      build_interaction(
        interaction_attrs("persist before broadcast",
          request_id: request_id,
          agent_id: "agent_durable_waiter"
        )
      )

    assert {:ok, ^request_id} =
             InteractionRouter.request(interaction,
               durability: :node_restart,
               adapter_map: %{}
             )

    waiter =
      Task.async(fn ->
        Arbor.Comms.await_interaction_response(request_id, interaction.agent_id, timeout: 250)
      end)

    assert_eventually(fn ->
      case DurableStore.get(request_id) do
        {:ok, %Record{data: %{"owner_deadline_unix_ms" => deadline}}} ->
          is_integer(deadline)

        _ ->
          false
      end
    end)

    assert {:ok, %Interaction{request_id: ^request_id}} =
             InteractionRegistry.resolve(request_id,
               response: :approved,
               metadata: %{"source" => "persisted"}
             )

    assert {:ok, before_restart} = DurableStore.get(request_id)
    assert before_restart.data["status"] == "responded"
    operation_id = before_restart.data["operation_id"]

    restart_authority()

    assert {:ok, after_restart} = DurableStore.get(request_id)
    assert after_restart.data["operation_id"] == operation_id

    assert {:ok, :approved, %{"source" => "persisted"}} = Task.await(waiter, 2_000)
  end

  test "security regression: owner waiter death preserves the durable operation for a replacement waiter" do
    request_id = "irq_durable_owner_waiter_death"
    agent_id = "agent_durable_owner_waiter_death"

    assert {:ok, ^request_id} =
             Arbor.Comms.request_interaction(
               interaction_attrs("owner waiter can die without losing authority",
                 request_id: request_id,
                 agent_id: agent_id
               ),
               durability: :node_restart,
               adapter_map: %{}
             )

    parent = self()

    owner_waiter =
      spawn(fn ->
        send(parent, {:owner_waiter_started, self()})

        Arbor.Comms.await_interaction_response(request_id, agent_id, timeout: 5_000)
      end)

    owner_monitor = Process.monitor(owner_waiter)
    assert_receive {:owner_waiter_started, ^owner_waiter}

    assert_eventually(fn ->
      match?(
        {:ok, %Record{data: %{"status" => "pending", "owner_deadline_unix_ms" => deadline}}}
        when is_integer(deadline),
        DurableStore.get(request_id)
      )
    end)

    assert {:ok, before_owner_death} = DurableStore.get(request_id)
    operation_id = before_owner_death.data["operation_id"]
    owner_deadline = before_owner_death.data["owner_deadline_unix_ms"]

    Process.exit(owner_waiter, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_waiter, :killed}

    assert {:ok, after_owner_death} = DurableStore.get(request_id)
    assert after_owner_death.data["operation_id"] == operation_id
    assert after_owner_death.data["owner_deadline_unix_ms"] == owner_deadline
    assert after_owner_death.data["status"] == "pending"

    replacement_waiter =
      Task.async(fn ->
        send(parent, :replacement_waiter_started)
        Arbor.Comms.await_interaction_response(request_id, agent_id, timeout: 5_000)
      end)

    assert_receive :replacement_waiter_started

    assert :ok =
             Arbor.Comms.respond_to_interaction(request_id, :approved, %{
               "source" => "replacement"
             })

    assert {:ok, :approved, %{"source" => "replacement"}} =
             Task.await(replacement_waiter, 2_000)

    assert {:ok, terminal_record} = DurableStore.get(request_id)
    assert terminal_record.data["operation_id"] == operation_id
    assert terminal_record.data["status"] == "responded"
  end

  test "security regression: duplicate durable answers have one terminal winner across restart" do
    request_id = "irq_durable_duplicate_answers"

    assert {:ok, ^request_id} =
             Arbor.Comms.request_interaction(
               interaction_attrs("conflicting operator answers", request_id: request_id),
               durability: :node_restart,
               adapter_map: %{}
             )

    parent = self()

    answer_task = fn response ->
      Task.async(fn ->
        send(parent, {:duplicate_answer_ready, response})

        receive do
          :submit_answer ->
            Arbor.Comms.respond_to_interaction(request_id, response, %{
              "answer" => Atom.to_string(response)
            })
        end
      end)
    end

    approved = answer_task.(:approved)
    rejected = answer_task.(:rejected)

    assert_receive {:duplicate_answer_ready, :approved}
    assert_receive {:duplicate_answer_ready, :rejected}
    send(approved.pid, :submit_answer)
    send(rejected.pid, :submit_answer)

    results = [approved: Task.await(approved), rejected: Task.await(rejected)]

    assert [{winner, :ok}] = Enum.filter(results, fn {_answer, result} -> result == :ok end)

    assert [{loser, {:error, {:already_terminal, :responded}}}] =
             Enum.reject(results, fn {_answer, result} -> result == :ok end)

    refute winner == loser

    assert {:ok, %{response: ^winner, metadata: %{"answer" => winner_metadata}}} =
             Arbor.Comms.get_interaction_response(request_id)

    assert winner_metadata == Atom.to_string(winner)
    assert {:ok, before_restart} = DurableStore.get(request_id)

    restart_authority()

    assert {:ok, %{response: ^winner, metadata: %{"answer" => ^winner_metadata}}} =
             Arbor.Comms.get_interaction_response(request_id)

    assert {:ok, after_restart} = DurableStore.get(request_id)
    assert after_restart.data["operation_id"] == before_restart.data["operation_id"]
    assert after_restart.data["status"] == "responded"
    assert after_restart.data["terminal"] == before_restart.data["terminal"]
  end

  test "security regression: a durable timeout rejects a late answer after authority restart" do
    request_id = "irq_durable_timeout_late_answer"
    agent_id = "agent_durable_timeout_late_answer"

    assert {:ok, ^request_id} =
             Arbor.Comms.request_interaction(
               interaction_attrs("late answer after timeout",
                 request_id: request_id,
                 agent_id: agent_id
               ),
               durability: :node_restart,
               adapter_map: %{}
             )

    assert {:error, :timeout} =
             Arbor.Comms.await_interaction_response(request_id, agent_id, timeout: 0)

    assert {:ok, before_restart} = DurableStore.get(request_id)
    assert before_restart.data["status"] == "abandoned"

    restart_authority()

    assert {:error, {:already_terminal, :abandoned}} =
             Arbor.Comms.respond_to_interaction(request_id, :approved, %{"source" => "late"})

    assert {:ok, after_restart} = DurableStore.get(request_id)
    assert after_restart.data["operation_id"] == before_restart.data["operation_id"]
    assert after_restart.data["status"] == "abandoned"
    assert after_restart.data["terminal"] == before_restart.data["terminal"]
  end

  test "security regression: degraded hydration rejects durable ID rebinding and late response",
       %{
         path: path
       } do
    request_id = "irq_durable_waiter_reused_id"

    durable_interaction =
      build_interaction(
        interaction_attrs("original durable operation",
          request_id: request_id,
          agent_id: "agent_reused_id_waiter"
        )
      )

    assert {:ok, ^request_id} =
             InteractionRouter.request(durable_interaction,
               durability: :node_restart,
               adapter_map: %{}
             )

    waiter =
      Task.async(fn ->
        Arbor.Comms.await_interaction_response(request_id, durable_interaction.agent_id,
          timeout: 1_000
        )
      end)

    assert_eventually(fn ->
      case DurableStore.get(request_id) do
        {:ok, %Record{data: %{"owner_deadline_unix_ms" => deadline}}} ->
          is_integer(deadline)

        _ ->
          false
      end
    end)

    terminal_id = "irq_degraded_terminal_tombstone"

    assert {:ok, ^terminal_id} =
             InteractionRouter.request(
               interaction_attrs("terminal before degraded hydration",
                 request_id: terminal_id,
                 agent_id: "agent_degraded_terminal"
               ),
               durability: :node_restart,
               adapter_map: %{}
             )

    assert {:ok, %Interaction{request_id: ^terminal_id}} =
             InteractionRegistry.resolve(terminal_id,
               response: :approved,
               metadata: %{"source" => "before restart"}
             )

    assert {:ok, pending_before_restart} = DurableStore.get(request_id)
    assert {:ok, terminal_before_restart} = DurableStore.get(terminal_id)

    malformed_id = "irq_reused_id_hydration_failure"
    :ok = Backend.put_raw(malformed_id, Record.new(malformed_id, %{"bad" => true}), path)
    restart_authority()

    reused_interaction = %{durable_interaction | description: "unrelated volatile operation"}

    assert {:error, :already_tracked} =
             InteractionRouter.request(reused_interaction, adapter_map: %{})

    assert {:error, {:already_terminal, :responded}} =
             InteractionRouter.request(
               build_interaction(
                 interaction_attrs("volatile terminal reuse",
                   request_id: terminal_id,
                   agent_id: "agent_degraded_terminal"
                 )
               ),
               adapter_map: %{}
             )

    assert {:error, :not_found} =
             InteractionRouter.respond(request_id, :rejected, %{"source" => "late response"})

    assert {:error, :timeout} = Task.await(waiter, 2_000)
    assert {:ok, pending_after_rejection} = DurableStore.get(request_id)

    assert pending_after_rejection.data["operation_id"] ==
             pending_before_restart.data["operation_id"]

    assert pending_after_rejection.data["interaction"] ==
             pending_before_restart.data["interaction"]

    assert pending_after_rejection.data["status"] == "pending"
    assert pending_after_rejection.data["terminal"] == nil

    assert {:ok, terminal_after_rejection} = DurableStore.get(terminal_id)

    assert terminal_after_rejection.data["operation_id"] ==
             terminal_before_restart.data["operation_id"]

    assert terminal_after_rejection.data["status"] == "responded"
    assert terminal_after_rejection.data["terminal"] == terminal_before_restart.data["terminal"]
    assert :not_found = InteractionRegistry.get(request_id)
  end

  test "security regression: ambiguous configured durable lookup blocks volatile admission" do
    assert {:error, :durable_unavailable} =
             InteractionRouter.request(
               interaction_attrs("ambiguous exact lookup",
                 request_id: "irq_ambiguous_durable_lookup"
               ),
               adapter_map: %{}
             )

    assert :not_found = InteractionRegistry.get("irq_ambiguous_durable_lookup")
  end

  test "durable pending state survives authority restart and claims a fresh epoch" do
    attrs = interaction_attrs("restart", request_id: "irq_durable_restart")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, first_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 5_000)

    {:ok, before_restart} = DurableStore.get(request_id)
    {:ok, before_data} = DurableLifecycleCore.decode(before_restart.data)
    old_authority = Process.whereis(Authority)
    restart_authority()

    assert old_authority != Process.whereis(Authority)
    assert {:ok, _interaction} = InteractionRegistry.get(request_id)

    assert {:ok, second_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 10_000)

    assert second_capture.operation_id == first_capture.operation_id
    refute second_capture.authority_epoch == first_capture.authority_epoch

    {:ok, after_restart} = DurableStore.get(request_id)
    {:ok, after_data} = DurableLifecycleCore.decode(after_restart.data)
    assert after_data["operation_id"] == before_data["operation_id"]
    assert after_data["owner_deadline_unix_ms"] == before_data["owner_deadline_unix_ms"]

    assert {:error, :authority_unavailable} =
             InteractionRegistry.finalize_timeout(first_capture, request_id)

    assert {:ok, %{status: :abandoned}} =
             InteractionRegistry.finalize_timeout(second_capture, request_id)
  end

  test "the earliest deadline remains in force across repeated arms and restart" do
    attrs = interaction_attrs("deadline", request_id: "irq_durable_deadline")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, first_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 2_000)

    {:ok, first_record} = DurableStore.get(request_id)
    {:ok, first_data} = DurableLifecycleCore.decode(first_record.data)

    assert {:ok, _second_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 60_000)

    {:ok, second_record} = DurableStore.get(request_id)
    {:ok, second_data} = DurableLifecycleCore.decode(second_record.data)
    assert second_data["owner_deadline_unix_ms"] == first_data["owner_deadline_unix_ms"]

    restart_authority()

    assert {:ok, _third_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 60_000)

    {:ok, third_record} = DurableStore.get(request_id)
    {:ok, third_data} = DurableLifecycleCore.decode(third_record.data)
    assert third_data["owner_deadline_unix_ms"] == first_data["owner_deadline_unix_ms"]
    assert is_binary(first_capture.authority_epoch)
  end

  test "response and timeout have one durable terminal winner" do
    attrs = interaction_attrs("race", request_id: "irq_durable_race")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 60_000)

    parent = self()

    responder =
      Task.async(fn ->
        send(parent, :response_ready)

        receive do
          :go ->
            InteractionRegistry.resolve(request_id,
              response: :approved,
              metadata: %{"decision" => "approve"}
            )
        end
      end)

    timer =
      Task.async(fn ->
        send(parent, :timeout_ready)

        receive do
          :go -> InteractionRegistry.finalize_timeout(capture, request_id)
        end
      end)

    assert_receive :response_ready
    assert_receive :timeout_ready
    send(responder.pid, :go)
    send(timer.pid, :go)
    results = [Task.await(responder), Task.await(timer)]
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:ok, terminal} = InteractionRegistry.get_terminal(request_id)
    assert terminal.status in [:responded, :abandoned]
  end

  test "durable abandonment is reduced and fenced before publication" do
    attrs = interaction_attrs("abandon", request_id: "irq_durable_abandon")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, %Interaction{request_id: ^request_id}} =
             InteractionRegistry.abandon(request_id, :await_timeout)

    assert {:ok, %{status: :abandoned, reason: :await_timeout}} =
             InteractionRegistry.get_terminal(request_id)

    assert {:ok, record} = DurableStore.get(request_id)
    assert {:ok, %{"status" => "abandoned"}} = DurableLifecycleCore.decode(record.data)
  end

  test "durable expiry is reduced through the real store CAS" do
    attrs =
      interaction_attrs("already expired",
        request_id: "irq_durable_expired",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      )

    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)
    assert :not_found = InteractionRegistry.get(request_id)

    assert {:ok, %{status: :expired, reason: :expires_at_elapsed}} =
             InteractionRegistry.get_terminal(request_id)

    assert {:ok, record} = DurableStore.get(request_id)
    assert {:ok, %{"status" => "expired"}} = DurableLifecycleCore.decode(record.data)
  end

  test "approval and text terminal responses round-trip through restart" do
    assert {:ok, approval_id} =
             InteractionRouter.request(
               interaction_attrs("approval", request_id: "irq_durable_approval"),
               durability: :node_restart
             )

    assert :ok = InteractionRouter.respond(approval_id, :approved, %{"decision" => "approve"})
    restart_authority()
    assert {:ok, approval_terminal} = InteractionRegistry.get_terminal(approval_id)
    assert approval_terminal.status == :responded
    assert approval_terminal.response == :approved
    assert approval_terminal.authority_node == node()

    text_attrs = interaction_attrs("text", kind: :clarification, request_id: "irq_durable_text")

    assert {:ok, text_id} =
             InteractionRouter.request(
               text_attrs,
               durability: :node_restart
             )

    assert :ok =
             InteractionRouter.respond(text_id, {:text, "hello"}, %{"source" => "operator"})

    assert {:ok, text_terminal} = InteractionRegistry.get_terminal(text_id)
    assert text_terminal.response == {:text, "hello"}
    assert text_terminal.metadata == %{"source" => "operator"}
  end

  test "disabled storage permits volatile admission while configured degradation fails closed" do
    Application.delete_env(:arbor_comms, :durable_interaction_store)
    restart_authority()
    assert {:error, :disabled} = InteractionRegistry.durable_readiness()

    assert {:ok, _volatile_id} =
             InteractionRouter.request(interaction_attrs("volatile", request_id: "irq_volatile"))

    assert {:error, :durable_unavailable} =
             InteractionRouter.request(interaction_attrs("disabled", request_id: "irq_disabled"),
               durability: :node_restart
             )

    Application.put_env(
      :arbor_comms,
      :durable_interaction_store,
      backend: ProcessLifetimeBackend,
      namespace: :durable_interaction_integration_test,
      opts: [],
      max_data_bytes: 65_536,
      max_items: 32
    )

    restart_authority()
    assert {:error, :unsupported} = InteractionRegistry.durable_readiness()

    assert {:error, :durable_unavailable} =
             InteractionRouter.request(
               interaction_attrs("volatile again", request_id: "irq_volatile_2")
             )

    assert {:error, :durable_unavailable} =
             InteractionRouter.request(interaction_attrs("degraded", request_id: "irq_degraded"),
               durability: :node_restart
             )
  end

  test "hydration never claims a record owned by another node" do
    interaction = build_interaction(interaction_attrs("foreign", request_id: "irq_foreign"))

    {:ok, data} =
      DurableLifecycleCore.new(interaction, "op_foreign", "other@node", "epoch_foreign", now_ms())

    assert {:ok, _record} = DurableStore.insert_once(interaction.request_id, data)

    restart_authority()
    assert :not_found = InteractionRegistry.get(interaction.request_id)
    assert {:ok, record} = DurableStore.get(interaction.request_id)
    assert {:ok, decoded} = DurableLifecycleCore.decode(record.data)
    assert decoded["authority_node"] == "other@node"
    assert decoded["authority_epoch"] == "epoch_foreign"
  end

  defp interaction_attrs(description, overrides) do
    Map.merge(
      %{
        request_id: "irq_#{System.unique_integer([:positive])}",
        kind: :approval,
        agent_id: "agent_durable",
        user_id: "user_durable",
        description: description,
        submitted_at: ~U[2026-01-01 00:00:00Z]
      },
      Map.new(overrides)
    )
  end

  defp build_interaction(attrs) do
    {:ok, interaction} = Interaction.new(attrs)
    interaction
  end

  defp track_dashboard(user_id) do
    assert {:ok, _ref} =
             PresenceTracker.track(self(), user_id, :dashboard, %{test_pid: self()})

    assert_eventually(fn ->
      match?([{:dashboard, _metadata}], PresenceTracker.active_channels(user_id))
    end)
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met within timeout")
      else
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
      end
    end
  end

  defp restart_authority do
    case Process.whereis(Authority) do
      pid when is_pid(pid) ->
        Process.exit(pid, :kill)

        unless wait_for_new_authority(pid, 100) do
          raise "authority did not restart"
        end

      nil ->
        {:ok, _} = start_supervised(Arbor.Comms.InteractionRegistry)
    end
  end

  defp wait_for_new_authority(_old_pid, 0), do: is_pid(Process.whereis(Authority))

  defp wait_for_new_authority(old_pid, attempts) do
    case Process.whereis(Authority) do
      new_pid when is_pid(new_pid) and new_pid != old_pid ->
        true

      _ ->
        Process.sleep(10)
        wait_for_new_authority(old_pid, attempts - 1)
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp restore_config(nil), do: Application.delete_env(:arbor_comms, :durable_interaction_store)

  defp restore_config(value),
    do: Application.put_env(:arbor_comms, :durable_interaction_store, value)

  defmodule Backend do
    alias Arbor.Contracts.Persistence.Record

    def start_link(path) do
      case Process.whereis(__MODULE__) do
        nil -> Agent.start_link(fn -> load(path) end, name: __MODULE__)
        _pid -> {:ok, __MODULE__}
      end
    end

    def stop do
      if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
      :ok
    catch
      :exit, _ -> :ok
    end

    def durability_class(_opts), do: :node_restart

    def get("irq_ambiguous_durable_lookup", _opts), do: {:error, :backend_unavailable}

    def get(key, _opts) do
      Agent.get(__MODULE__, fn state ->
        case Map.fetch(state, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end)
    end

    def list(_opts), do: Agent.get(__MODULE__, fn state -> {:ok, Map.keys(state)} end)

    def put_raw(key, %Record{} = record, path) do
      Agent.update(__MODULE__, fn state ->
        next = Map.put(state, key, record)
        persist([path: path], next)
        next
      end)
    end

    def compare_and_swap(key, :not_found, %Record{} = replacement, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state, key) do
          nil ->
            stored = %{replacement | generation: 1, revision: 1}
            next = Map.put(state, key, stored)
            persist(opts, next)
            {{:ok, stored}, next}

          _ ->
            {{:error, :conflict}, state}
        end
      end)
    end

    def compare_and_swap(key, {:value, %Record{} = expected}, %Record{} = replacement, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state, key) do
          %Record{generation: generation, revision: revision} = current
          when generation == expected.generation and revision == expected.revision ->
            stored = %{
              replacement
              | id: current.id,
                key: current.key,
                generation: current.generation,
                revision: current.revision + 1,
                inserted_at: current.inserted_at
            }

            next = Map.put(state, key, stored)
            persist(opts, next)
            {{:ok, stored}, next}

          _ ->
            {{:error, :conflict}, state}
        end
      end)
    end

    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}

    defp persist(opts, state),
      do: File.write!(Keyword.fetch!(opts, :path), :erlang.term_to_binary(state))

    defp load(path) do
      case File.read(path) do
        {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
        {:error, :enoent} -> %{}
      end
    end
  end

  defmodule ProcessLifetimeBackend do
    def durability_class(_opts), do: :process_lifetime
    def get(_key, _opts), do: {:error, :not_found}
    def list(_opts), do: {:ok, []}
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}
  end
end
