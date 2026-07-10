defmodule Arbor.AI.AcpTaskControlTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.AcpManaged.SessionRegistry
  alias Arbor.AI.AcpSession

  @moduletag :fast

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
    {:ok, session} = AcpSession.start_link(provider: :test, client_opts: [test_pid: self()])
    session
  end

  defp control(id, message),
    do: %{"control_id" => id, "message" => message, "task_id" => "task-1"}

  test "busy controls queue and drain in order through the same ACP client and session" do
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

  test "ready sessions defer controls and invalid controls do not enter the queue" do
    session = start_session()

    assert {:ok, :deferred, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-ready", "later"))

    assert {:ok, :deferred, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-ready", "later"))

    assert {:error, :invalid_control_message} =
             AcpSession.deliver_task_control(session, control("bad", ""))
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

  test "task-control history prunes terminal entries at its bounded limit" do
    session = start_session()

    for index <- 1..257 do
      assert {:ok, :deferred, :same_session_follow_up} =
               AcpSession.deliver_task_control(session, control("history-#{index}", "later"))
    end

    state = :sys.get_state(session)
    assert map_size(state.task_controls) == 256
    refute Map.has_key?(state.task_controls, "history-1")
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

  test "prompt failure cleans up queued controls without executing them" do
    session = start_session()
    caller = Task.async(fn -> AcpSession.send_message(session, "initial", timeout: 1_000) end)

    assert_receive {:prompt_started, worker, _client, "same-session", "initial"}

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-error", "never"))

    send(worker, {:release, {:error, :provider_failed}})

    assert {:error, :provider_failed} = Task.await(caller)
    refute_receive {:prompt_started, _worker, _client, "same-session", "never"}, 50

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, control("c-error", "never"))
  end

  test "caller cancellation aborts the active prompt and does not run queued controls" do
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
