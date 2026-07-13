defmodule Arbor.AI.AcpTaskControlTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.AcpManaged.SessionRegistry
  alias Arbor.AI.AcpSession
  alias Arbor.Signals
  alias Arbor.Signals.Signal

  @moduletag :fast

  setup_all do
    for module <- [Arbor.Signals.Store, Arbor.Signals.Bus] do
      unless Process.whereis(module), do: start_supervised!({module, []})
    end

    :ok
  end

  defmodule FakeClient do
    @moduledoc false

    def start_link(opts), do: Agent.start_link(fn -> opts end)

    def new_session(_client, _cwd, _opts), do: {:ok, %{"sessionId" => "same-session"}}
    def load_session(_client, id, _cwd, _opts), do: {:ok, %{"sessionId" => id}}
    def set_config_option(_client, _session_id, _key, _value), do: :ok

    def disconnect(client) do
      opts = Agent.get(client, & &1)
      send(opts[:test_pid], {:disconnected, client})
      Agent.stop(client, :normal)
    end

    def cancel(client, session_id) do
      opts = Agent.get(client, & &1)
      send(opts[:test_pid], {:cancelled, client, session_id})
      :ok
    end

    def prompt(client, session_id, content, _opts) do
      opts = Agent.get(client, & &1)
      send(opts[:test_pid], {:prompt_started, self(), client, session_id, content})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :fake_timeout}
      end
    end
  end

  defmodule ControlSession do
    @moduledoc false

    def deliver_task_control(pid, control, _opts) do
      send(pid, {:managed_control, control})
      {:ok, :queued, :same_session_follow_up}
    end
  end

  setup do
    original = Application.get_env(:arbor_ai, :acp_client_module)
    Application.put_env(:arbor_ai, :acp_client_module, FakeClient)

    on_exit(fn ->
      if original,
        do: Application.put_env(:arbor_ai, :acp_client_module, original),
        else: Application.delete_env(:arbor_ai, :acp_client_module)
    end)

    :ok
  end

  defp start_session do
    {:ok, session} =
      AcpSession.start_link(
        provider: :test,
        agent_id: "agent-test",
        owner: nil,
        client_opts: [test_pid: self()]
      )

    on_exit(fn -> close_session(session) end)
    session
  end

  defp close_session(session) do
    if Process.alive?(session) do
      previous_client = Application.get_env(:arbor_ai, :acp_client_module)
      Application.put_env(:arbor_ai, :acp_client_module, FakeClient)

      try do
        AcpSession.close(session)
      catch
        :exit, _reason -> :ok
      after
        if previous_client,
          do: Application.put_env(:arbor_ai, :acp_client_module, previous_client),
          else: Application.delete_env(:arbor_ai, :acp_client_module)
      end
    end
  end

  defp control(id, message),
    do: %{"control_id" => id, "message" => message, "task_id" => "task-1"}

  defp subscribe_to_task_control_signals do
    test_pid = self()

    {:ok, subscription_id} =
      Signals.subscribe(
        "agent.*",
        fn %Signal{type: type} = signal ->
          if String.starts_with?(Atom.to_string(type), "acp_task_control_") do
            send(test_pid, {:task_control_signal, signal})
          end

          :ok
        end,
        async: false
      )

    on_exit(fn -> Signals.unsubscribe(subscription_id) end)
  end

  defp assert_durable_control_signal(type, control_id, status, reason) do
    assert_receive {:task_control_signal, %Signal{type: ^type, data: data}}, 1_000
    assert data.control_id == control_id
    assert data.task_id == "task-1"
    assert data.agent_id == "agent-test"
    assert data.session_id in [nil, "same-session"]
    assert data.provider == :test
    assert data.mode == :same_session_follow_up
    assert data.status == status
    assert data.reason == reason
    assert data.permanent == true
    refute Map.has_key?(data, :message)
    refute Map.has_key?(data, :session_pid)
    refute Enum.any?(Map.values(data), &is_pid/1)
    data
  end

  defp install_pending_timeout_settlement(session, control_id) do
    ref = make_ref()
    session_id = "pending-#{control_id}"

    terminal_control = %{
      control_id: control_id,
      message: "must-not-run",
      task_id: "task-1",
      status: :not_delivered,
      reason: :provider_prompt_timed_out_before_delivery
    }

    settlement = %{
      kind: :timeout,
      control_events: [
        {
          :acp_task_control_not_delivered,
          terminal_control,
          :provider_prompt_timed_out_before_delivery
        }
      ]
    }

    :sys.replace_state(session, fn state ->
      %{
        state
        | session_id: session_id,
          last_session_id: session_id,
          status: :recovery_required,
          task_controls: Map.put(state.task_controls, control_id, terminal_control),
          task_control_history_order: state.task_control_history_order ++ [control_id],
          pending_settlements: %{ref => settlement},
          pending_settlement_order: [ref]
      }
    end)

    {ref, session_id}
  end

  defp subscribe_to_settlement_signals(session_id) do
    test_pid = self()

    {:ok, subscription_id} =
      Signals.subscribe(
        "agent.*",
        fn %Signal{type: type, data: data} = signal ->
          if Map.get(data, :session_id) == session_id and
               type in [
                 :acp_task_control_not_delivered,
                 :acp_session_error,
                 :acp_session_closed
               ] do
            send(test_pid, {:settlement_signal, signal})
          end

          :ok
        end,
        async: false
      )

    on_exit(fn -> Signals.unsubscribe(subscription_id) end)
  end

  defp assert_timeout_settlement_once(control_id, close_expected? \\ false) do
    assert_receive {:settlement_signal,
                    %Signal{
                      type: :acp_task_control_not_delivered,
                      data: %{control_id: ^control_id}
                    }},
                   1_000

    assert_receive {:settlement_signal,
                    %Signal{type: :acp_session_error, data: %{error: :timeout}}},
                   1_000

    if close_expected? do
      assert_receive {:settlement_signal, %Signal{type: :acp_session_closed}}, 1_000
    end

    refute_receive {:settlement_signal, %Signal{type: :acp_task_control_not_delivered}},
                   50

    refute_receive {:settlement_signal, %Signal{type: :acp_session_error}}, 50
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  test "busy controls queue and drain in order through the same ACP client and session" do
    subscribe_to_task_control_signals()
    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)

    assert_receive {:prompt_started, initial_worker, client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-1", "follow-1"))

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-2", "follow-2"))

    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})
    assert_receive {:prompt_started, first_worker, ^client, "same-session", "follow-1"}
    send(first_worker, {:release, {:ok, %{"text" => "first"}}})
    assert_receive {:prompt_started, second_worker, ^client, "same-session", "follow-2"}
    send(second_worker, {:release, {:ok, %{"text" => "last"}}})

    assert {:ok, %{"text" => "last"}} = Task.await(caller)

    assert {:ok, :delivered, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-1", "follow-1"))

    assert_durable_control_signal(
      :acp_task_control_queued,
      "c-1",
      :queued,
      :accepted_while_prompt_active
    )

    assert_durable_control_signal(
      :acp_task_control_delivered,
      "c-1",
      :delivered,
      :provider_prompt_completed
    )

    assert {:ok, :delivered, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-1", "ignored"))

    refute_receive {:task_control_signal,
                    %Signal{type: :acp_task_control_delivered, data: %{control_id: "c-1"}}},
                   50
  end

  test "controls arriving during a follow-up append after the existing queue" do
    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)

    assert_receive {:prompt_started, initial_worker, _client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-1", "follow-1"))

    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})

    assert_receive {:prompt_started, first_worker, _client, "same-session", "follow-1"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-2", "follow-2"))

    send(first_worker, {:release, {:ok, %{"text" => "first"}}})

    assert_receive {:prompt_started, second_worker, _client, "same-session", "follow-2"}
    send(second_worker, {:release, {:ok, %{"text" => "last"}}})
    assert {:ok, %{"text" => "last"}} = Task.await(caller)
  end

  test "security regression: queued follow-ups retain the initial prompt deadline" do
    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 80) end)

    assert_receive {:prompt_started, initial_worker, client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("deadline-follow", "follow"))

    Process.sleep(50)
    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})
    assert_receive {:prompt_started, _follow_worker, ^client, "same-session", "follow"}

    assert {:ok, {:error, :timeout}} = Task.yield(caller, 60)
    assert_receive {:cancelled, ^client, "same-session"}
    assert Process.alive?(session)

    assert %{status: :recovery_required, session_id: "same-session"} =
             AcpSession.status(session)
  end

  test "ready sessions defer controls and invalid controls do not enter the queue" do
    subscribe_to_task_control_signals()
    session = start_session()

    assert {:ok, :deferred, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-ready", "later"))

    assert {:ok, :deferred, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-ready", "later"))

    assert {:error, :invalid_control_message} =
             AcpSession.deliver_task_control(session, control("bad", ""))

    assert_durable_control_signal(
      :acp_task_control_unsupported,
      "c-ready",
      :deferred,
      :native_steer_unavailable
    )

    assert_durable_control_signal(
      :acp_task_control_deferred,
      "c-ready",
      :deferred,
      :no_active_prompt
    )

    refute_receive {:task_control_signal,
                    %Signal{type: :acp_task_control_deferred, data: %{control_id: "c-ready"}}},
                   50
  end

  test "a deferred control retries once into the next busy prompt and delivers once" do
    session = start_session()

    assert {:ok, :deferred, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-deferred", "original-follow-up"))

    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)
    assert_receive {:prompt_started, initial_worker, _client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(
               session,
               control("c-deferred", "replacement-must-not-run")
             )

    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})

    assert_receive {:prompt_started, follow_up_worker, _client, "same-session",
                    "original-follow-up"}

    send(follow_up_worker, {:release, {:ok, %{"text" => "last"}}})

    assert {:ok, %{"text" => "last"}} = Task.await(caller)

    refute_receive {:prompt_started, _worker, _client, "same-session",
                    "replacement-must-not-run"},
                   50

    assert {:ok, :delivered, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-deferred", "ignored"))
  end

  test "task-control history prunes terminal entries but preserves deferred controls" do
    session = start_session()

    ids = Enum.map(1..256, &"history-#{&1}")

    :sys.replace_state(session, fn state ->
      controls =
        Map.new(ids, fn id ->
          {id,
           %{
             control_id: id,
             message: "later",
             task_id: "task-1",
             status: :deferred
           }}
        end)

      %{state | task_controls: controls, task_control_history_order: ids}
    end)

    assert {:error, :task_control_history_full} =
             AcpSession.deliver_task_control(session, control("history-257", "later"))

    state = :sys.get_state(session)
    assert map_size(state.task_controls) == 256
    assert Map.has_key?(state.task_controls, "history-1")

    :sys.replace_state(session, fn state ->
      oldest = Map.fetch!(state.task_controls, "history-1")

      %{
        state
        | task_controls:
            Map.put(state.task_controls, "history-1", %{
              oldest
              | status: :delivered
            })
      }
    end)

    assert {:ok, :deferred, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("history-257", "later"))

    state = :sys.get_state(session)
    assert map_size(state.task_controls) == 256
    refute Map.has_key?(state.task_controls, "history-1")
    assert Map.has_key?(state.task_controls, "history-257")
  end

  test "busy task-control queue rejects backpressure beyond its bounded limit" do
    session = start_session()
    session_ref = Process.monitor(session)
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:prompt_result, AcpSession.send_message(session, "initial", timeout: 1_000)}
        )
      end)

    assert_receive {:prompt_started, _worker, client, "same-session", "initial"}

    for index <- 1..64 do
      assert {:ok, :queued, :same_session_follow_up} =
               AcpSession.deliver_task_control(session, control("queued-#{index}", "later"))
    end

    assert {:error, :task_control_queue_full} =
             AcpSession.deliver_task_control(session, control("queued-overflow", "later"))

    Process.exit(caller, :kill)
    assert_receive {:cancelled, ^client, "same-session"}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
  end

  test "initial prompt failure terminally marks waiting controls not delivered" do
    subscribe_to_task_control_signals()
    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)

    assert_receive {:prompt_started, worker, _client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-error", "never"))

    send(worker, {:release, {:error, :provider_failed}})

    assert {:error, :provider_failed} = Task.await(caller)
    refute_receive {:prompt_started, _worker, _client, "same-session", "never"}, 50

    terminal =
      {:error, {:task_control_terminal, :not_delivered, :provider_prompt_failed_before_delivery}}

    assert ^terminal =
             AcpSession.deliver_task_control(session, control("c-error", "never"))

    assert ^terminal =
             AcpSession.deliver_task_control(session, control("c-error", "never"))

    state = :sys.get_state(session)
    assert state.task_controls["c-error"].status == :not_delivered

    assert_durable_control_signal(
      :acp_task_control_not_delivered,
      "c-error",
      :not_delivered,
      :provider_prompt_failed_before_delivery
    )

    refute_receive {:task_control_signal,
                    %Signal{
                      type: :acp_task_control_not_delivered,
                      data: %{control_id: "c-error"}
                    }},
                   50
  end

  test "follow-up failure makes the active control unknown and aborts the remaining queue" do
    subscribe_to_task_control_signals()
    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)

    assert_receive {:prompt_started, initial_worker, _client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-active", "follow-active"))

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-waiting", "follow-waiting"))

    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})

    assert_receive {:prompt_started, active_worker, _client, "same-session", "follow-active"}
    send(active_worker, {:release, {:error, :provider_failed}})

    assert {:error, :provider_failed} = Task.await(caller)

    refute_receive {:prompt_started, _worker, _client, "same-session", "follow-waiting"}, 50

    active_terminal =
      {:error, {:task_control_terminal, :delivery_unknown, :provider_delivery_failed}}

    waiting_terminal =
      {:error, {:task_control_terminal, :not_delivered, :provider_prompt_failed_before_delivery}}

    assert ^active_terminal =
             AcpSession.deliver_task_control(session, control("c-active", "must-not-replay"))

    assert ^waiting_terminal =
             AcpSession.deliver_task_control(session, control("c-waiting", "must-not-run"))

    assert ^active_terminal =
             AcpSession.deliver_task_control(session, control("c-active", "must-not-replay"))

    refute_receive {:prompt_started, _worker, _client, "same-session", "must-not-replay"}, 50

    assert_durable_control_signal(
      :acp_task_control_delivery_unknown,
      "c-active",
      :delivery_unknown,
      :provider_delivery_failed
    )

    assert_durable_control_signal(
      :acp_task_control_not_delivered,
      "c-waiting",
      :not_delivered,
      :provider_prompt_failed_before_delivery
    )

    refute_receive {:task_control_signal,
                    %Signal{
                      type: :acp_task_control_delivery_unknown,
                      data: %{control_id: "c-active"}
                    }},
                   50
  end

  test "follow-up timeout leaves active delivery unknown and marks waiting controls not delivered" do
    subscribe_to_task_control_signals()
    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)

    assert_receive {:prompt_started, initial_worker, client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("timeout-active", "follow-active"))

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(
               session,
               control("timeout-waiting", "follow-waiting")
             )

    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})
    assert_receive {:prompt_started, active_worker, ^client, "same-session", "follow-active"}
    send(active_worker, {:release, {:error, :timeout}})

    assert {:error, :timeout} = Task.await(caller)
    assert_receive {:cancelled, ^client, "same-session"}
    refute_receive {:disconnected, ^client}, 50
    assert Process.alive?(session)

    assert %{status: :recovery_required, session_id: "same-session"} =
             AcpSession.status(session)

    assert {:error, {:not_ready, :recovery_required}} =
             AcpSession.deliver_task_control(
               session,
               control("timeout-after-recovery", "must-not-run")
             )

    refute_receive {:prompt_started, _worker, _client, "same-session", "follow-waiting"}, 50

    assert_durable_control_signal(
      :acp_task_control_delivery_unknown,
      "timeout-active",
      :delivery_unknown,
      :provider_delivery_timed_out
    )

    assert_durable_control_signal(
      :acp_task_control_not_delivered,
      "timeout-waiting",
      :not_delivered,
      :provider_prompt_timed_out_before_delivery
    )
  end

  @tag timeout: 2_000
  test "security regression: timeout replies before queued task-control settlement work" do
    test_pid = self()

    {:ok, subscription_id} =
      Signals.subscribe(
        "agent.*",
        fn
          %Signal{type: :acp_task_control_delivery_unknown} ->
            send(test_pid, {:settlement_started, self()})

            receive do
              :release_settlement -> :ok
            end

          _signal ->
            :ok
        end,
        async: false
      )

    on_exit(fn -> Signals.unsubscribe(subscription_id) end)

    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)

    assert_receive {:prompt_started, initial_worker, _client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("settlement", "follow"))

    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})
    assert_receive {:prompt_started, active_worker, _client, "same-session", "follow"}
    send(active_worker, {:release, {:error, :timeout}})

    assert {:error, :timeout} = Task.await(caller)
    assert_receive {:settlement_started, settlement_pid}

    send(settlement_pid, :release_settlement)
    assert %{status: :recovery_required} = AcpSession.status(session)
  end

  test "security regression: settlement wakeups reject forged payloads and emit once" do
    session = start_session()
    control_id = "wakeup-once"
    {ref, session_id} = install_pending_timeout_settlement(session, control_id)
    subscribe_to_settlement_signals(session_id)

    forged_control = %{
      control_id: "forged",
      task_id: "task-1",
      status: :not_delivered,
      reason: :forged
    }

    send(session, {
      :acp_timeout_settlement,
      ref,
      [{:acp_task_control_not_delivered, forged_control, :forged}]
    })

    send(session, {:acp_timeout_settlement, :not_a_reference})
    send(session, {:acp_timeout_settlement})
    send(session, {:acp_timeout_settlement, make_ref()})
    send(session, {:acp_timeout_settlement, ref})
    send(session, {:acp_timeout_settlement, ref})

    assert %{status: :recovery_required} = AcpSession.status(session)
    assert_timeout_settlement_once(control_id)

    state = :sys.get_state(session)
    assert state.pending_settlements == %{}
    assert state.pending_settlement_order == []
    refute_receive {:settlement_signal, %Signal{data: %{control_id: "forged"}}}, 50
  end

  test "security regression: close queued before wakeup flushes the settlement once" do
    session = start_session()
    session_ref = Process.monitor(session)
    control_id = "close-race"
    {ref, session_id} = install_pending_timeout_settlement(session, control_id)
    subscribe_to_settlement_signals(session_id)

    :ok = :sys.suspend(session)
    close_task = Task.async(fn -> AcpSession.close(session) end)

    assert eventually(fn ->
             case Process.info(session, :messages) do
               {:messages, messages} ->
                 Enum.any?(messages, &match?({:"$gen_call", _from, {:close, _opts}}, &1))

               nil ->
                 false
             end
           end)

    send(session, {:acp_timeout_settlement, ref})
    :ok = :sys.resume(session)

    assert :ok = Task.await(close_task)
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
    assert_timeout_settlement_once(control_id, true)
  end

  test "security regression: owner DOWN queued before wakeup flushes the settlement once" do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, session} =
          AcpSession.start_link(
            provider: :test,
            agent_id: "agent-test",
            client_opts: [test_pid: test_pid]
          )

        send(test_pid, {:owned_session, session})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned_session, session}
    session_ref = Process.monitor(session)
    control_id = "owner-race"
    {ref, session_id} = install_pending_timeout_settlement(session, control_id)
    subscribe_to_settlement_signals(session_id)
    owner_monitor = :sys.get_state(session).owner_monitor

    :ok = :sys.suspend(session)
    send(session, {:DOWN, owner_monitor, :process, owner, :killed})
    send(session, {:acp_timeout_settlement, ref})
    :ok = :sys.resume(session)

    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
    assert_timeout_settlement_once(control_id, true)
    Process.exit(owner, :kill)
  end

  test "caller cancellation aborts the active prompt and does not run queued controls" do
    subscribe_to_task_control_signals()
    session = start_session()
    session_ref = Process.monitor(session)
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:prompt_result, AcpSession.send_message(session, "initial", timeout: 1_000)}
        )
      end)

    assert_receive {:prompt_started, _worker, client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-cancel", "never"))

    Process.exit(caller, :kill)

    assert_receive {:cancelled, ^client, "same-session"}
    assert_receive {:disconnected, ^client}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
    refute_receive {:prompt_started, _worker, _client, "same-session", "never"}, 50

    assert_durable_control_signal(
      :acp_task_control_cancelled,
      "c-cancel",
      :cancelled,
      :caller_cancelled
    )
  end

  test "cancellation leaves an active follow-up unknown and cancels controls not started" do
    subscribe_to_task_control_signals()
    session = start_session()
    session_ref = Process.monitor(session)
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:prompt_result, AcpSession.send_message(session, "initial", timeout: 1_000)}
        )
      end)

    assert_receive {:prompt_started, initial_worker, client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("cancel-active", "follow-active"))

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("cancel-waiting", "follow-waiting"))

    send(initial_worker, {:release, {:ok, %{"text" => "initial"}}})
    assert_receive {:prompt_started, _active_worker, ^client, "same-session", "follow-active"}

    Process.exit(caller, :kill)

    assert_receive {:cancelled, ^client, "same-session"}
    assert_receive {:disconnected, ^client}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
    refute_receive {:prompt_started, _worker, _client, "same-session", "follow-waiting"}, 50

    assert_durable_control_signal(
      :acp_task_control_delivery_unknown,
      "cancel-active",
      :delivery_unknown,
      :caller_cancelled_during_delivery
    )

    assert_durable_control_signal(
      :acp_task_control_cancelled,
      "cancel-waiting",
      :cancelled,
      :caller_cancelled
    )
  end

  test "task/principal control authority resolves one live session and rejects ambiguity" do
    registry = :"task_control_registry_#{System.unique_integer([:positive])}"
    start_supervised!({SessionRegistry, name: registry})
    {:ok, session} = Agent.start_link(fn -> :ok end)

    attrs = %{
      session_pid: session,
      session_module: ControlSession,
      provider: :test,
      task_id: "task-1",
      principal_id: "agent-1"
    }

    assert {:ok, _} = SessionRegistry.register(attrs, server: registry)

    assert {:ok, resolved} =
             SessionRegistry.resolve_task_control("task-1", "agent-1", server: registry)

    assert resolved.session_pid == session

    assert {:error, :not_found} =
             SessionRegistry.resolve_task_control("task-1", "", server: registry)

    assert {:ok, _} = SessionRegistry.register(attrs, server: registry)

    assert {:error, :ambiguous_task_control_session} =
             SessionRegistry.resolve_task_control("task-1", "agent-1", server: registry)
  end

  test "managed facade delivers only by task and principal" do
    registry = :"task_control_facade_registry_#{System.unique_integer([:positive])}"
    start_supervised!({SessionRegistry, name: registry})

    assert {:ok, _} =
             SessionRegistry.register(
               %{
                 session_pid: self(),
                 session_module: ControlSession,
                 provider: :test,
                 task_id: "task-1",
                 principal_id: "agent-1"
               },
               server: registry
             )

    assert {:ok, :queued, :same_session_follow_up} =
             AI.acp_managed_deliver_task_control(
               "task-1",
               "agent-1",
               %{"control_id" => "managed-1", "message" => "continue"},
               server: registry
             )

    assert_receive {:managed_control, %{"task_id" => "task-1", "control_id" => "managed-1"}}
  end

  test "capability reporting defaults to follow-up and permits explicit operator declaration" do
    assert %{native_steer: false, native_steer_acknowledged: false, same_session_follow_up: true} =
             AI.acp_task_control_capabilities(:gemini)

    original = Application.get_env(:arbor_ai, :acp_providers)

    Application.put_env(:arbor_ai, :acp_providers, %{
      future: %{task_control: %{native_steer: true}}
    })

    assert %{
             native_steer: false,
             native_steer_configured: true,
             native_steer_acknowledged: false,
             same_session_follow_up: true,
             fallback_mode: :same_session_follow_up
           } =
             AI.acp_task_control_capabilities(:future)

    if original,
      do: Application.put_env(:arbor_ai, :acp_providers, original),
      else: Application.delete_env(:arbor_ai, :acp_providers)
  end
end
