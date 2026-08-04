defmodule Arbor.Voice.BackendWorkerTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.BackendWorker
  alias Arbor.Voice.BackendWorkerSupervisor

  @moduletag :fast

  @route %{
    destination: "api.x.ai",
    provider: "xai",
    runtime: "arbor",
    model: "grok-voice-latest"
  }

  defmodule Backend do
    @behaviour Arbor.Voice.RealtimeBackend

    @impl true
    def egress_route, do: :none

    @impl true
    def open(opts) do
      parent = Keyword.fetch!(opts, :parent)
      mode = Keyword.get(opts, :mode, :normal)
      secret = Keyword.get(opts, :secret, "ordinary-session")
      authorizer = Keyword.fetch!(opts, :effect_authorizer)
      route = Keyword.get(opts, :callback_route, :none)

      send(parent, {:backend_called, :open, self(), 0})

      case mode do
        :hang_open ->
          receive do
            :never_open -> {:error, :unreachable}
          end

        :effect ->
          authorization = authorizer.(:connect, route)
          send(parent, {:effect_authorization, authorization})

          if authorization == :allow do
            send(parent, {:physical_effect, self()})
            {:ok, session(parent, mode, secret, authorizer, route)}
          else
            {:error, {:distinctive_denial, secret}}
          end

        _other ->
          {:ok, session(parent, mode, secret, authorizer, route)}
      end
    end

    @impl true
    def configure(session, _config) do
      send(session.parent, {:backend_called, :configure, self(), session.version})

      case session.mode do
        :blocking_configure ->
          receive do
            :release_configure -> {:ok, bump(session)}
          end

        :invalid_configure ->
          {:ok, session, :wrong_shape}

        :faulting_configure ->
          raise "distinctive-configure-fault"

        _other ->
          {:ok, bump(session)}
      end
    end

    @impl true
    def send_text(session, _text) do
      send(session.parent, {:backend_called, :send_text, self(), session.version})

      case session.mode do
        :partial_send ->
          {:error, {:distinctive_partial_error, session.secret}, bump(session)}

        :send_error ->
          {:error, {:distinctive_raw_error, session.secret}}

        _other ->
          {:ok, bump(session)}
      end
    end

    @impl true
    def send_audio(session, _audio) do
      send(session.parent, {:backend_called, :send_audio, self(), session.version})
      {:ok, bump(session)}
    end

    @impl true
    def send_tool_result(session, _call_id, _output) do
      send(session.parent, {:backend_called, :send_tool_result, self(), session.version})
      {:ok, bump(session)}
    end

    @impl true
    def recv(session, _timeout) do
      send(session.parent, {:backend_called, :recv, self(), session.version})
      {:ok, bump(session), {:turn_done, %{text: "done"}}}
    end

    @impl true
    def meta(session) do
      send(session.parent, {:backend_called, :meta, self(), session.version})
      %{backend: :test_backend, mode: :cloud, input_rate: 16_000, output_rate: 24_000}
    end

    @impl true
    def close(session) do
      send(
        session.parent,
        {:backend_called, :close, self(), session.version, session.secret}
      )

      :ok
    end

    defp session(parent, mode, secret, authorizer, route) do
      %{
        parent: parent,
        mode: mode,
        secret: secret,
        authorizer: authorizer,
        route: route,
        version: 0
      }
    end

    defp bump(session), do: %{session | version: session.version + 1}
  end

  setup do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = BackendWorkerSupervisor.start_link(name: nil)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    end)

    %{supervisor: supervisor}
  end

  test "hanging open dies at its exact deadline and leaves no supervised orphan", ctx do
    {worker, generation, worker_token} =
      start_worker(ctx.supervisor, [parent: self(), mode: :hang_open], :none)

    monitor = Process.monitor(worker)
    operation_token = BackendWorker.new_operation_token()
    deadline = now_ms() + 80

    assert :ok =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               operation_token,
               deadline,
               :open,
               []
             )

    assert_receive {:backend_called, :open, ^worker, 0}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    refute_receive {:voice_backend_operation_result, ^worker, _, _, _, _, _, _}, 50
    assert_eventually_no_children(ctx.supervisor)
  end

  test "one socket-owning process performs open configure send recv meta and close", ctx do
    {worker, generation, worker_token} = start_worker(ctx.supervisor, [parent: self()], :none)

    open = submit_result(worker, generation, worker_token, :open, [])
    assert_receive {:backend_called, :open, ^worker, 0}
    assert open.outcome == :ok
    assert :ok = ack(worker, generation, worker_token, open.token)

    operations = [
      {:configure, [%{instructions: "hello"}], 0, :ok},
      {:send_text, ["text"], 1, :ok},
      {:send_audio, [<<1, 2, 3>>], 2, :ok},
      {:send_tool_result, ["call_1", "output"], 3, :ok},
      {:recv, [50], 4, {:ok, {:turn_done, %{text: "done"}}}},
      {:meta, [], 5,
       {:ok, %{backend: :test_backend, mode: :cloud, input_rate: 16_000, output_rate: 24_000}}}
    ]

    Enum.each(operations, fn {operation, args, version, expected} ->
      result = submit_result(worker, generation, worker_token, operation, args)
      assert_receive {:backend_called, ^operation, ^worker, ^version}
      assert result.outcome == expected
      assert :ok = ack(worker, generation, worker_token, result.token)
    end)

    monitor = Process.monitor(worker)
    close = submit_result(worker, generation, worker_token, :close, [])
    assert_receive {:backend_called, :close, ^worker, 5, "ordinary-session"}
    assert close.outcome == :ok
    refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 25
    assert :ok = ack(worker, generation, worker_token, close.token)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  test "effect RPC binds exact worker token and faults or timeouts deny before effect", ctx do
    {worker, generation, worker_token} =
      start_worker(
        ctx.supervisor,
        [parent: self(), mode: :effect, callback_route: @route],
        @route,
        effect_timeout_ms: 60
      )

    open_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               open_token,
               now_ms() + 1_000,
               :open,
               []
             )

    assert_receive request =
                     {:voice_backend_effect_request, ^worker, ^generation, ^worker_token,
                      effect_token, :connect, @route, reply_alias}

    assert is_reference(effect_token)
    assert is_reference(reply_alias)
    assert :ok = BackendWorker.reply_effect(request, :allow)
    assert_receive {:physical_effect, ^worker}
    assert_receive {:effect_authorization, :allow}

    assert_receive {:voice_backend_operation_result, ^worker, ^generation, ^worker_token,
                    ^open_token, :open, completed_at, :ok}

    assert is_integer(completed_at)
    assert :ok = ack(worker, generation, worker_token, open_token)
    close_worker(worker, generation, worker_token)

    Enum.each([:wrong_token, :fault, :timeout], fn refusal ->
      {denied_worker, denied_generation, denied_token} =
        start_worker(
          ctx.supervisor,
          [parent: self(), mode: :effect, callback_route: @route],
          @route,
          effect_timeout_ms: 40
        )

      operation_token = BackendWorker.new_operation_token()

      assert :ok =
               BackendWorker.submit(
                 denied_worker,
                 denied_generation,
                 denied_token,
                 operation_token,
                 now_ms() + 1_000,
                 :open,
                 []
               )

      assert_receive denied_request =
                       {:voice_backend_effect_request, ^denied_worker, ^denied_generation,
                        ^denied_token, denied_effect_token, :connect, @route, denied_reply_alias}

      case refusal do
        :wrong_token ->
          send(
            denied_reply_alias,
            {:voice_backend_effect_reply, denied_worker, denied_generation,
             :crypto.strong_rand_bytes(32), denied_effect_token, :connect, @route, :allow}
          )

        :fault ->
          assert :ok =
                   BackendWorker.reply_effect(
                     denied_request,
                     {:error, {:distinctive_authorizer_fault, make_ref()}}
                   )

        :timeout ->
          :ok
      end

      assert_receive {:effect_authorization, {:error, :backend_effect_denied}}, 500

      assert_receive {:voice_backend_operation_result, ^denied_worker, ^denied_generation,
                      ^denied_token, ^operation_token, :open, _completed_at,
                      {:error, :backend_open_failed}},
                     500

      refute_receive {:physical_effect, ^denied_worker}, 25
      denied_monitor = Process.monitor(denied_worker)
      assert :ok = ack(denied_worker, denied_generation, denied_token, operation_token)
      assert_receive {:DOWN, ^denied_monitor, :process, ^denied_worker, :normal}, 500
    end)
  end

  test "terminal result precedes DOWN and exact ack fences every following operation", ctx do
    {worker, generation, worker_token} =
      start_worker(ctx.supervisor, [parent: self(), mode: :invalid_configure], :none)

    open = submit_result(worker, generation, worker_token, :open, [])
    assert :ok = ack(worker, generation, worker_token, open.token)

    monitor = Process.monitor(worker)
    invalid = submit_result(worker, generation, worker_token, :configure, [%{}])
    assert invalid.outcome == {:error, :invalid_backend_return}
    assert_receive {:backend_called, :close, ^worker, 0, "ordinary-session"}
    refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 25

    assert {:error, :operation_pending} =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               make_ref(),
               now_ms() + 1_000,
               :meta,
               []
             )

    assert {:error, :stale_ack} = ack(worker, generation, worker_token, make_ref())
    refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 25
    assert :ok = ack(worker, generation, worker_token, invalid.token)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  test "partial send retains the latest opaque state for same-process close", ctx do
    secret = "partial-session-secret-9a0d"

    {worker, generation, worker_token} =
      start_worker(
        ctx.supervisor,
        [parent: self(), mode: :partial_send, secret: secret],
        :none
      )

    open = submit_result(worker, generation, worker_token, :open, [])
    assert :ok = ack(worker, generation, worker_token, open.token)

    monitor = Process.monitor(worker)
    partial = submit_result(worker, generation, worker_token, :send_text, ["sensitive-text"])
    assert partial.outcome == {:error, :backend_partial_failure}
    assert_receive {:backend_called, :close, ^worker, 1, ^secret}
    refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 25
    assert :ok = ack(worker, generation, worker_token, partial.token)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  test "stale malformed overlapping and foreign operations fail closed", ctx do
    {worker, generation, worker_token} = start_worker(ctx.supervisor, [parent: self()], :none)
    valid_token = BackendWorker.new_operation_token()
    future = now_ms() + 1_000

    assert {:error, :stale_generation} =
             BackendWorker.submit(
               worker,
               make_ref(),
               worker_token,
               valid_token,
               future,
               :open,
               []
             )

    assert {:error, :invalid_worker_token} =
             BackendWorker.submit(
               worker,
               generation,
               :crypto.strong_rand_bytes(32),
               valid_token,
               future,
               :open,
               []
             )

    assert {:error, :invalid_operation_token} =
             BackendWorker.submit(worker, generation, worker_token, "bad", future, :open, [])

    assert {:error, :invalid_deadline} =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               valid_token,
               :tomorrow,
               :open,
               []
             )

    assert {:error, :deadline_expired} =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               valid_token,
               now_ms() - 1,
               :open,
               []
             )

    assert {:error, :open_required} =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               valid_token,
               future,
               :meta,
               []
             )

    parent = self()

    spawn(fn ->
      result =
        BackendWorker.submit(
          worker,
          generation,
          worker_token,
          make_ref(),
          now_ms() + 1_000,
          :open,
          []
        )

      send(parent, {:foreign_result, result})
    end)

    assert_receive {:foreign_result, {:error, :foreign_coordinator}}

    open = submit_result(worker, generation, worker_token, :open, [])

    assert {:error, :operation_pending} =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               make_ref(),
               now_ms() + 1_000,
               :configure,
               [%{}]
             )

    assert {:error, :stale_ack} = ack(worker, generation, worker_token, make_ref())
    assert :ok = ack(worker, generation, worker_token, open.token)

    assert {:error, :invalid_operation} =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               make_ref(),
               now_ms() + 1_000,
               :configure,
               ["not-a-map"]
             )

    close_worker(worker, generation, worker_token)
  end

  test "coordinator kill cannot orphan a worker blocked in open", ctx do
    parent = self()
    generation = make_ref()

    coordinator =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        {:ok, worker, worker_token} =
          BackendWorkerSupervisor.start_worker(
            ctx.supervisor,
            self(),
            generation,
            Backend,
            [parent: parent, mode: :hang_open],
            :none,
            ack_timeout_ms: 500
          )

        send(parent, {:coordinator_worker, self(), worker, worker_token})

        receive do
          :open ->
            :ok =
              BackendWorker.submit(
                worker,
                generation,
                worker_token,
                make_ref(),
                now_ms() + 5_000,
                :open,
                []
              )

            send(parent, {:open_submitted, self()})

            receive do
              :never_finish -> :ok
            end
        end
      end)

    assert_receive {:coordinator_worker, ^coordinator, worker, _worker_token}
    worker_monitor = Process.monitor(worker)
    coordinator_monitor = Process.monitor(coordinator)
    send(coordinator, :open)
    assert_receive {:open_submitted, ^coordinator}
    assert_receive {:backend_called, :open, ^worker, 0}

    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    assert_eventually_no_children(ctx.supervisor)
  end

  test "normal coordinator death closes the session and retires the worker", ctx do
    parent = self()
    generation = make_ref()

    coordinator =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        {:ok, worker, worker_token} =
          BackendWorkerSupervisor.start_worker(
            ctx.supervisor,
            self(),
            generation,
            Backend,
            [parent: parent, secret: "coordinator-death-session"],
            :none,
            ack_timeout_ms: 500
          )

        open = submit_result(worker, generation, worker_token, :open, [])
        :ok = ack(worker, generation, worker_token, open.token)
        send(parent, {:coordinator_ready_to_exit, self(), worker})

        receive do
          :exit_normally -> :ok
        end
      end)

    assert_receive {:coordinator_ready_to_exit, ^coordinator, worker}
    monitor = Process.monitor(worker)
    send(coordinator, :exit_normally)
    assert_receive {:backend_called, :close, ^worker, 0, "coordinator-death-session"}, 500
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    assert_eventually_no_children(ctx.supervisor)
  end

  test "state status results and Inspect redact distinctive secrets", ctx do
    backend_secret = "backend-opt-and-session-secret-f48b"
    route_secret = "route-secret-b32a"
    operation_secret = "text-and-tool-output-secret-a7ce"

    route = %{
      destination: route_secret,
      provider: "provider-#{route_secret}",
      runtime: "runtime-#{route_secret}",
      model: "model-#{route_secret}"
    }

    {worker, generation, worker_token} =
      start_worker(
        ctx.supervisor,
        [parent: self(), mode: :send_error, secret: backend_secret],
        route,
        ack_timeout_ms: 2_000
      )

    open = submit_result(worker, generation, worker_token, :open, [])
    assert :ok = ack(worker, generation, worker_token, open.token)

    terminal =
      submit_result(worker, generation, worker_token, :send_text, [operation_secret])

    assert terminal.outcome == {:error, :backend_callback_failed}
    assert_receive {:backend_called, :close, ^worker, 0, ^backend_secret}

    state_inspection = worker |> :sys.get_state() |> inspect()
    status_inspection = worker |> :sys.get_status() |> inspect()
    result_inspection = inspect(terminal)

    Enum.each([state_inspection, status_inspection, result_inspection], fn inspection ->
      refute inspection =~ backend_secret
      refute inspection =~ route_secret
      refute inspection =~ operation_secret
      refute inspection =~ "distinctive_raw_error"
      refute inspection =~ inspect(worker_token)
    end)

    monitor = Process.monitor(worker)
    assert :ok = ack(worker, generation, worker_token, terminal.token)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  test "callback faults are terminal and raw exception content never crosses the boundary", ctx do
    {worker, generation, worker_token} =
      start_worker(ctx.supervisor, [parent: self(), mode: :faulting_configure], :none)

    open = submit_result(worker, generation, worker_token, :open, [])
    assert :ok = ack(worker, generation, worker_token, open.token)

    monitor = Process.monitor(worker)
    fault = submit_result(worker, generation, worker_token, :configure, [%{}])
    assert fault.outcome == {:error, :backend_callback_fault}
    refute inspect(fault) =~ "distinctive-configure-fault"
    assert_receive {:backend_called, :close, ^worker, 0, "ordinary-session"}
    assert :ok = ack(worker, generation, worker_token, fault.token)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  defp start_worker(supervisor, backend_opts, route, worker_opts \\ []) do
    generation = make_ref()

    assert {:ok, worker, worker_token} =
             BackendWorkerSupervisor.start_worker(
               supervisor,
               self(),
               generation,
               Backend,
               backend_opts,
               route,
               Keyword.merge(
                 [effect_timeout_ms: 100, ack_timeout_ms: 1_000, retire_timeout_ms: 500],
                 worker_opts
               )
             )

    assert is_pid(worker)
    assert is_binary(worker_token)
    assert byte_size(worker_token) == 32
    {worker, generation, worker_token}
  end

  defp submit_result(worker, generation, worker_token, operation, args) do
    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               generation,
               worker_token,
               operation_token,
               now_ms() + 1_000,
               operation,
               args
             )

    assert_receive {:voice_backend_operation_result, ^worker, ^generation, ^worker_token,
                    ^operation_token, ^operation, completed_at, outcome},
                   1_000

    assert is_integer(completed_at)
    %{token: operation_token, completed_at: completed_at, outcome: outcome}
  end

  defp ack(worker, generation, worker_token, operation_token) do
    BackendWorker.ack(worker, generation, worker_token, operation_token)
  end

  defp close_worker(worker, generation, worker_token) do
    monitor = Process.monitor(worker)
    result = submit_result(worker, generation, worker_token, :close, [])
    assert result.outcome == :ok
    assert :ok = ack(worker, generation, worker_token, result.token)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    :ok
  end

  defp assert_eventually_no_children(supervisor, attempts \\ 20)

  defp assert_eventually_no_children(supervisor, 0) do
    assert DynamicSupervisor.which_children(supervisor) == []
  end

  defp assert_eventually_no_children(supervisor, attempts) do
    if DynamicSupervisor.which_children(supervisor) == [] do
      :ok
    else
      Process.sleep(10)
      assert_eventually_no_children(supervisor, attempts - 1)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
