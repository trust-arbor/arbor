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

  test "security regression: stale durable waiter cannot bind a reused volatile ID", %{path: path} do
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

    malformed_id = "irq_reused_id_hydration_failure"
    :ok = Backend.put_raw(malformed_id, Record.new(malformed_id, %{"bad" => true}), path)
    restart_authority()

    reused_interaction = %{durable_interaction | description: "unrelated volatile operation"}

    assert {:ok, ^request_id} =
             InteractionRouter.request(reused_interaction, adapter_map: %{})

    assert :ok =
             InteractionRouter.respond(request_id, :rejected, %{"source" => "reused operation"})

    assert {:error, :timeout} = Task.await(waiter, 2_000)
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

  test "disabled and degraded durable storage fail closed while volatile remains available" do
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

    assert {:ok, _volatile_id} =
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
