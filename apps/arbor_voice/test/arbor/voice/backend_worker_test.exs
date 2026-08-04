defmodule Arbor.Voice.BackendWorkerTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.BackendWorker
  alias Arbor.Voice.BackendWorker.CompletionCredential
  alias Arbor.Voice.BackendWorker.Credential
  alias Arbor.Voice.BackendWorker.EffectRequest
  alias Arbor.Voice.BackendWorker.Result
  alias Arbor.Voice.BackendWorkerSupervisor
  alias Arbor.Voice.Redacted

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

        mode when mode in [:effect, :effect_send_error] ->
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

        :configure_error ->
          {:error, {:distinctive_configure_error, session.secret}}

        :partial_configure ->
          {:error, {:distinctive_partial_configure, session.secret}, bump(session)}

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

        mode when mode in [:send_error, :effect_send_error] ->
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
    {worker, credential} =
      start_worker(ctx.supervisor, [parent: self(), mode: :hang_open], :none)

    monitor = Process.monitor(worker)
    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               operation_token,
               now_ms() + 80,
               :open,
               []
             )

    assert_receive {:backend_called, :open, ^worker, 0}
    assert_receive down = {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    refute inspect(down) =~ "ordinary-session"
    refute_receive {:voice_backend_operation_result, %Result{worker: ^worker}}, 50
    assert_eventually_no_children(ctx.supervisor)
  end

  test "one socket-owning process performs open configure send recv meta and close", ctx do
    {worker, credential} = start_worker(ctx.supervisor, [parent: self()], :none)

    open = submit_result(worker, credential, :open, [])
    assert_receive {:backend_called, :open, ^worker, 0}
    assert open.outcome == :ok
    assert :ok = ack(worker, credential, open)

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
      result = submit_result(worker, credential, operation, args)
      assert_receive {:backend_called, ^operation, ^worker, ^version}
      assert result.outcome == expected
      assert :ok = ack(worker, credential, result)
    end)

    monitor = Process.monitor(worker)
    close = submit_result(worker, credential, :close, [])
    assert_receive {:backend_called, :close, ^worker, 5, "ordinary-session"}
    assert close.outcome == :ok
    refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 25
    assert :ok = ack(worker, credential, close)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  test "foreign holder of an exact effect request cannot authorize a physical effect", ctx do
    {worker, credential} =
      start_worker(
        ctx.supervisor,
        [parent: self(), mode: :effect, callback_route: @route],
        @route,
        effect_timeout_ms: 250
      )

    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               operation_token,
               now_ms() + 1_000,
               :open,
               []
             )

    assert_receive %EffectRequest{
                     worker: ^worker,
                     coordinator: coordinator,
                     generation: generation,
                     operation_token: ^operation_token,
                     effect: :connect,
                     frozen_route: @route
                   } = request

    assert coordinator == self()
    assert generation == credential.generation
    assert {:ok, ^request} = BackendWorker.verify_effect_request(request, credential)

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:foreign_effect_reply, BackendWorker.reply_effect(request, :allow),
         BackendWorker.verify_effect_request(request, credential),
         BackendWorker.reply_effect(request, credential, :allow)}
      )
    end)

    assert_receive {:foreign_effect_reply, {:error, :invalid_effect_request},
                    {:error, :invalid_effect_request}, {:error, :invalid_effect_request}}

    refute_receive {:physical_effect, ^worker}, 25

    assert :ok = BackendWorker.reply_effect(request, credential, :allow)
    assert_receive {:physical_effect, ^worker}
    assert_receive {:effect_authorization, :allow}

    open = receive_result(worker, credential, operation_token, :open)
    assert open.outcome == :ok
    assert :ok = ack(worker, credential, open)
    close_worker(worker, credential)
  end

  test "security regression: effect request authenticates every material field", ctx do
    {worker, credential} =
      start_worker(
        ctx.supervisor,
        [parent: self(), mode: :effect, callback_route: @route],
        @route,
        effect_timeout_ms: 1_000
      )

    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               operation_token,
               now_ms() + 2_000,
               :open,
               []
             )

    assert_receive %EffectRequest{} = request
    assert {:ok, ^request} = BackendWorker.verify_effect_request(request, credential)

    tampered_requests = [
      %{request | worker: self()},
      %{request | coordinator: worker},
      %{request | generation: make_ref()},
      %{request | operation_token: make_ref()},
      %{request | effect_token: make_ref()},
      %{request | effect: :configure},
      %{request | frozen_route: %{@route | model: "tampered-model"}},
      %{request | reply_alias: make_ref()},
      %{request | authenticator: Redacted.new(:crypto.strong_rand_bytes(32))},
      Map.put(request, :unsigned_extra, :value)
    ]

    Enum.each(tampered_requests, fn tampered ->
      assert {:error, :invalid_effect_request} =
               BackendWorker.verify_effect_request(tampered, credential)

      assert {:error, :invalid_effect_request} =
               BackendWorker.reply_effect(tampered, credential, :allow)
    end)

    assert :ok = BackendWorker.reply_effect(request, credential, :allow)
    assert_receive {:physical_effect, ^worker}
    open = receive_result(worker, credential, operation_token, :open)
    assert :ok = ack(worker, credential, open)
    close_worker(worker, credential)
  end

  test "effect decisions are bounded to allow or deny before reply authentication", ctx do
    {worker, credential} =
      start_worker(
        ctx.supervisor,
        [parent: self(), mode: :effect, callback_route: @route],
        @route,
        effect_timeout_ms: 1_000
      )

    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               operation_token,
               now_ms() + 2_000,
               :open,
               []
             )

    assert_receive %EffectRequest{} = request
    assert {:ok, ^request} = BackendWorker.verify_effect_request(request, credential)

    Enum.each(
      [nil, :unknown, {:error, make_ref()}, String.duplicate("x", 1_000_000)],
      fn decision ->
        assert {:error, :invalid_effect_request} =
                 BackendWorker.reply_effect(request, credential, decision)
      end
    )

    refute_receive {:physical_effect, ^worker}, 25
    assert :ok = BackendWorker.reply_effect(request, credential, :deny)
    assert_receive {:effect_authorization, {:error, :backend_effect_denied}}
    refute_receive {:physical_effect, ^worker}, 25

    denied = receive_result(worker, credential, operation_token, :open)
    assert denied.outcome == {:error, :backend_open_failed}
    monitor = Process.monitor(worker)
    assert :ok = ack(worker, credential, denied)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  test "faulting malformed and timeout effect responses deny before transport", ctx do
    Enum.each([:fault, :malformed_credential, :timeout], fn refusal ->
      {worker, credential} =
        start_worker(
          ctx.supervisor,
          [parent: self(), mode: :effect, callback_route: @route],
          @route,
          effect_timeout_ms: 40
        )

      operation_token = BackendWorker.new_operation_token()

      assert :ok =
               BackendWorker.submit(
                 worker,
                 credential,
                 operation_token,
                 now_ms() + 1_000,
                 :open,
                 []
               )

      assert_receive %EffectRequest{worker: ^worker} = request

      case refusal do
        :fault ->
          assert {:error, :invalid_effect_request} =
                   BackendWorker.reply_effect(
                     request,
                     credential,
                     {:error, {:distinctive_authorizer_fault, make_ref()}}
                   )

        :malformed_credential ->
          fake = %Credential{credential | secret: Redacted.new(:crypto.strong_rand_bytes(32))}

          assert {:error, :invalid_effect_request} =
                   BackendWorker.reply_effect(request, fake, :allow)

        :timeout ->
          :ok
      end

      assert_receive {:effect_authorization, {:error, :backend_effect_denied}}, 500
      denied = receive_result(worker, credential, operation_token, :open)
      assert denied.outcome == {:error, :backend_open_failed}
      refute_receive {:physical_effect, ^worker}, 25

      monitor = Process.monitor(worker)
      assert :ok = ack(worker, credential, denied)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    end)
  end

  test "worker-minted completion rejects an ACK sent before callback completion", ctx do
    {worker, credential} =
      start_worker(ctx.supervisor, [parent: self(), mode: :blocking_configure], :none)

    open = submit_result(worker, credential, :open, [])
    assert :ok = ack(worker, credential, open)

    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               operation_token,
               now_ms() + 1_000,
               :configure,
               [%{}]
             )

    assert_receive {:backend_called, :configure, ^worker, 0}

    fake_completion = %CompletionCredential{value: Redacted.new(make_ref())}

    spawn(fn ->
      Process.sleep(25)
      send(worker, :release_configure)
    end)

    assert {:error, :stale_ack} =
             BackendWorker.ack(worker, credential, operation_token, fake_completion)

    configured = receive_result(worker, credential, operation_token, :configure)
    assert configured.outcome == :ok

    assert {:error, :operation_pending} =
             BackendWorker.submit(
               worker,
               credential,
               make_ref(),
               now_ms() + 1_000,
               :send_text,
               ["must-not-run"]
             )

    refute_receive {:backend_called, :send_text, ^worker, _version}, 25
    assert :ok = ack(worker, credential, configured)
    close_worker(worker, credential)
  end

  test "signed forged oversized and bignum results fail closed before HMAC verification", ctx do
    {worker, credential} = start_worker(ctx.supervisor, [parent: self()], :none)
    open = submit_result(worker, credential, :open, [])

    oversized_audio =
      :binary.copy(<<0>>, BackendWorker.max_audio_bytes() + 65_537)

    oversized =
      open.result
      |> Map.put(:operation, :recv)
      |> Map.put(:outcome, {:ok, {:output_audio, oversized_audio}})
      |> sign_result(credential)

    huge_integer = :binary.decode_unsigned(<<1>> <> :binary.copy(<<0>>, 131_072))

    huge_completed_at =
      open.result
      |> Map.put(:completed_at, huge_integer)
      |> sign_result(credential)

    huge_meta_rate =
      open.result
      |> Map.put(:operation, :meta)
      |> Map.put(:outcome, {
        :ok,
        %{
          backend: :test_backend,
          mode: :cloud,
          input_rate: huge_integer,
          output_rate: 24_000
        }
      })
      |> sign_result(credential)

    Enum.each([oversized, huge_completed_at, huge_meta_rate], fn forged ->
      assert {:error, :invalid_result} = BackendWorker.verify_result(forged, credential)
      assert {:error, :invalid_result} = BackendWorker.ack(worker, credential, forged)
    end)

    assert {:ok, _verified} = BackendWorker.verify_result(open.result, credential)
    assert :ok = ack(worker, credential, open)
    close_worker(worker, credential)
  end

  test "every configure error fault malformed or partial result quarantines the connection",
       ctx do
    cases = [
      {:configure_error, {:error, :backend_callback_failed}, 0},
      {:faulting_configure, {:error, :backend_callback_fault}, 0},
      {:invalid_configure, {:error, :invalid_backend_return}, 0},
      {:partial_configure, {:error, :backend_partial_failure}, 1}
    ]

    Enum.each(cases, fn {mode, expected, close_version} ->
      {worker, credential} = start_worker(ctx.supervisor, [parent: self(), mode: mode], :none)
      open = submit_result(worker, credential, :open, [])
      assert :ok = ack(worker, credential, open)

      monitor = Process.monitor(worker)
      failed = submit_result(worker, credential, :configure, [%{}])
      assert failed.outcome == expected
      assert_receive {:backend_called, :close, ^worker, ^close_version, "ordinary-session"}

      assert {:error, :operation_pending} =
               BackendWorker.submit(
                 worker,
                 credential,
                 make_ref(),
                 now_ms() + 1_000,
                 :send_text,
                 ["must-not-run"]
               )

      refute_receive {:backend_called, :send_text, ^worker, _version}, 25
      refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 10
      assert :ok = ack(worker, credential, failed)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    end)
  end

  test "partial send closes the latest opaque state before terminal result acknowledgement",
       ctx do
    secret = "partial-session-secret-9a0d"

    {worker, credential} =
      start_worker(
        ctx.supervisor,
        [parent: self(), mode: :partial_send, secret: secret],
        :none
      )

    open = submit_result(worker, credential, :open, [])
    assert :ok = ack(worker, credential, open)

    monitor = Process.monitor(worker)
    partial = submit_result(worker, credential, :send_text, ["sensitive-text"])
    assert partial.outcome == {:error, :backend_partial_failure}
    assert_receive {:backend_called, :close, ^worker, 1, ^secret}
    refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 25
    assert :ok = ack(worker, credential, partial)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
  end

  test "stale malformed overlapping foreign and tampered protocol terms fail closed", ctx do
    {worker, credential} = start_worker(ctx.supervisor, [parent: self()], :none)
    operation_token = BackendWorker.new_operation_token()
    future = now_ms() + 1_000

    stale = %Credential{credential | generation: make_ref()}

    assert {:error, :stale_generation} =
             BackendWorker.submit(worker, stale, operation_token, future, :open, [])

    fake = %Credential{credential | secret: Redacted.new(:crypto.strong_rand_bytes(32))}

    assert {:error, :invalid_operation_authenticator} =
             BackendWorker.submit(worker, fake, operation_token, future, :open, [])

    assert {:error, :invalid_operation_token} =
             BackendWorker.submit(worker, credential, "bad", future, :open, [])

    parent = self()

    spawn(fn ->
      result =
        BackendWorker.submit(worker, credential, make_ref(), now_ms() + 1_000, :open, [])

      send(parent, {:foreign_result, result})
    end)

    assert_receive {:foreign_result, {:error, :foreign_coordinator}}

    open = submit_result(worker, credential, :open, [])

    tampered = %{open.result | outcome: {:ok, {:output_text_delta, "forged"}}}
    assert {:error, :invalid_result} = BackendWorker.verify_result(tampered, credential)
    assert {:error, :invalid_result} = BackendWorker.ack(worker, credential, tampered)

    assert {:error, :operation_pending} =
             BackendWorker.submit(
               worker,
               credential,
               make_ref(),
               now_ms() + 1_000,
               :configure,
               [%{}]
             )

    assert :ok = ack(worker, credential, open)
    close_worker(worker, credential)
  end

  test "deadline distance and operation aggregate bounds reject before callback", ctx do
    {worker, credential} = start_worker(ctx.supervisor, [parent: self()], :none)

    assert {:error, :deadline_too_far} =
             BackendWorker.submit(
               worker,
               credential,
               make_ref(),
               now_ms() + BackendWorker.max_deadline_distance_ms() + 1,
               :open,
               []
             )

    assert {:error, :deadline_expired} =
             BackendWorker.submit(worker, credential, make_ref(), now_ms() - 1, :open, [])

    refute_receive {:backend_called, :open, ^worker, 0}, 25

    open = submit_result(worker, credential, :open, [])
    assert :ok = ack(worker, credential, open)

    oversized_config = %{instructions: String.duplicate("c", BackendWorker.max_config_bytes())}
    oversized_audio = :binary.copy(<<0>>, BackendWorker.max_audio_bytes() + 1)

    refused = [
      {:configure, [oversized_config]},
      {:send_text, [String.duplicate("t", 8_193)]},
      {:send_audio, [oversized_audio]},
      {:send_tool_result, [String.duplicate("i", 257), "output"]},
      {:send_tool_result, ["id", String.duplicate("o", 8_193)]}
    ]

    Enum.each(refused, fn {operation, args} ->
      assert {:error, :invalid_operation} =
               BackendWorker.submit(
                 worker,
                 credential,
                 make_ref(),
                 now_ms() + 1_000,
                 operation,
                 args
               )

      refute_receive {:backend_called, ^operation, ^worker, _version}, 10
    end)

    close_worker(worker, credential)
  end

  test "route backend option and DynamicSupervisor capacity are source bounded", ctx do
    oversized_route = %{@route | destination: String.duplicate("r", 2_049)}

    assert {:error, :worker_start_failed} =
             BackendWorkerSupervisor.start_worker(
               ctx.supervisor,
               self(),
               make_ref(),
               Backend,
               [parent: self()],
               oversized_route,
               []
             )

    keys = [
      :a,
      :b,
      :c,
      :d,
      :e,
      :f,
      :g,
      :h,
      :i,
      :j,
      :k,
      :l,
      :m,
      :n,
      :o,
      :p,
      :q,
      :r,
      :s,
      :t,
      :u,
      :v,
      :w,
      :x,
      :y,
      :z,
      :aa,
      :ab,
      :ac,
      :ad,
      :ae,
      :af,
      :ag
    ]

    too_many_opts = Enum.map(keys, &{&1, 1})

    assert {:error, :worker_start_failed} =
             BackendWorkerSupervisor.start_worker(
               ctx.supervisor,
               self(),
               make_ref(),
               Backend,
               too_many_opts,
               :none,
               []
             )

    assert {:error, :worker_start_failed} =
             BackendWorkerSupervisor.start_worker(
               ctx.supervisor,
               self(),
               make_ref(),
               Backend,
               [parent: self(), oversized: String.duplicate("b", 65_537)],
               :none,
               []
             )

    workers =
      for _index <- 1..BackendWorkerSupervisor.max_children() do
        assert {:ok, worker, %Credential{}} =
                 BackendWorkerSupervisor.start_worker(
                   ctx.supervisor,
                   self(),
                   make_ref(),
                   Backend,
                   [parent: self()],
                   :none,
                   []
                 )

        worker
      end

    assert {:error, :worker_start_failed} =
             BackendWorkerSupervisor.start_worker(
               ctx.supervisor,
               self(),
               make_ref(),
               Backend,
               [parent: self()],
               :none,
               []
             )

    Enum.each(workers, fn worker ->
      assert :ok = DynamicSupervisor.terminate_child(ctx.supervisor, worker)
    end)
  end

  test "coordinator kill cannot orphan a worker blocked in open", ctx do
    parent = self()

    coordinator =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        {:ok, worker, credential} =
          BackendWorkerSupervisor.start_worker(
            ctx.supervisor,
            self(),
            make_ref(),
            Backend,
            [parent: parent, mode: :hang_open],
            :none,
            ack_timeout_ms: 500
          )

        send(parent, {:coordinator_worker, self(), worker})

        receive do
          :open ->
            :ok =
              BackendWorker.submit(
                worker,
                credential,
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

    assert_receive {:coordinator_worker, ^coordinator, worker}
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

    coordinator =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        {:ok, worker, credential} =
          BackendWorkerSupervisor.start_worker(
            ctx.supervisor,
            self(),
            make_ref(),
            Backend,
            [parent: parent, secret: "coordinator-death-session"],
            :none,
            ack_timeout_ms: 500
          )

        open = submit_result(worker, credential, :open, [])
        :ok = ack(worker, credential, open)
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

  test "actual credentials requests results state and status redact distinctive secrets", ctx do
    backend_secret = "backend-opt-and-session-secret-f48b"
    route_secret = "route-secret-b32a"
    operation_secret = "text-and-tool-output-secret-a7ce"

    route = %{
      destination: route_secret,
      provider: "provider-#{route_secret}",
      runtime: "runtime-#{route_secret}",
      model: "model-#{route_secret}"
    }

    {worker, credential} =
      start_worker(
        ctx.supervisor,
        [
          parent: self(),
          mode: :effect_send_error,
          secret: backend_secret,
          callback_route: route
        ],
        route,
        ack_timeout_ms: 2_000,
        effect_timeout_ms: 500
      )

    worker_secret = credential.secret |> Redacted.value()
    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               operation_token,
               now_ms() + 1_000,
               :open,
               []
             )

    assert_receive %EffectRequest{} = effect_request

    assert {:ok, ^effect_request} =
             BackendWorker.verify_effect_request(effect_request, credential)

    refute contains_exact_binary?(effect_request, worker_secret)
    refute inspect(effect_request) =~ route_secret
    refute inspect(effect_request) =~ inspect(operation_token)
    assert :ok = BackendWorker.reply_effect(effect_request, credential, :allow)
    assert_receive {:physical_effect, ^worker}

    open = receive_result(worker, credential, operation_token, :open)
    refute contains_exact_binary?(open.result, worker_secret)
    refute inspect({:voice_backend_operation_result, open.result}) =~ backend_secret
    refute inspect(open.result) =~ route_secret
    refute inspect(open.result) =~ inspect(operation_token)

    refute inspect(open.result.completion) =~
             inspect(Redacted.value(open.result.completion.value))

    refute inspect(credential) =~ inspect(worker_secret)
    assert :ok = ack(worker, credential, open)

    error_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               error_token,
               now_ms() + 1_000,
               :send_text,
               [operation_secret]
             )

    terminal = receive_result(worker, credential, error_token, :send_text)
    assert terminal.outcome == {:error, :backend_callback_failed}
    assert_receive {:backend_called, :close, ^worker, 0, ^backend_secret}

    inspections = [
      inspect(:sys.get_state(worker)),
      inspect(:sys.get_status(worker)),
      inspect(terminal.result),
      inspect({:voice_backend_operation_result, terminal.result}),
      inspect(credential)
    ]

    Enum.each(inspections, fn inspection ->
      refute inspection =~ backend_secret
      refute inspection =~ route_secret
      refute inspection =~ operation_secret
      refute inspection =~ "distinctive_raw_error"
      refute inspection =~ inspect(worker_secret)
      refute inspection =~ inspect(error_token)
    end)

    refute contains_exact_binary?(terminal.result, worker_secret)

    monitor = Process.monitor(worker)
    assert :ok = ack(worker, credential, terminal)
    assert_receive down = {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    refute inspect(down) =~ backend_secret
    refute inspect(down) =~ operation_secret
  end

  defp start_worker(supervisor, backend_opts, route, worker_opts \\ []) do
    assert {:ok, worker, %Credential{} = credential} =
             BackendWorkerSupervisor.start_worker(
               supervisor,
               self(),
               make_ref(),
               Backend,
               backend_opts,
               route,
               Keyword.merge(
                 [effect_timeout_ms: 100, ack_timeout_ms: 1_000, retire_timeout_ms: 500],
                 worker_opts
               )
             )

    assert is_pid(worker)
    assert credential.worker == worker
    assert credential.coordinator == self()
    assert is_reference(credential.generation)
    refute inspect(credential) =~ inspect(Redacted.value(credential.secret))
    {worker, credential}
  end

  defp submit_result(worker, credential, operation, args) do
    operation_token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               operation_token,
               now_ms() + 1_000,
               operation,
               args
             )

    receive_result(worker, credential, operation_token, operation)
  end

  defp receive_result(worker, credential, operation_token, operation) do
    assert_receive {:voice_backend_operation_result,
                    %Result{
                      worker: ^worker,
                      operation_token: ^operation_token,
                      operation: ^operation
                    } = result},
                   1_000

    assert {:ok, verified} = BackendWorker.verify_result(result, credential)
    assert is_integer(verified.completed_at)

    %{
      result: result,
      token: operation_token,
      completed_at: verified.completed_at,
      outcome: verified.outcome
    }
  end

  defp ack(worker, credential, %{result: result}) do
    BackendWorker.ack(worker, credential, result)
  end

  defp sign_result(result, credential) do
    completion = Redacted.value(result.completion.value)

    fields =
      {result.worker, result.coordinator, result.generation, result.operation_token,
       result.operation, result.completed_at, result.outcome, completion}

    payload = :erlang.term_to_binary({BackendWorker, :result, fields}, [:deterministic])
    secret = Redacted.value(credential.secret)
    %{result | authenticator: Redacted.new(:crypto.mac(:hmac, :sha256, secret, payload))}
  end

  defp close_worker(worker, credential) do
    monitor = Process.monitor(worker)
    result = submit_result(worker, credential, :close, [])
    assert result.outcome == :ok
    assert :ok = ack(worker, credential, result)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    :ok
  end

  defp contains_exact_binary?(term, target) when is_binary(term), do: term == target

  defp contains_exact_binary?(term, target) when is_list(term),
    do: Enum.any?(term, &contains_exact_binary?(&1, target))

  defp contains_exact_binary?(term, target) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_exact_binary?(&1, target))

  defp contains_exact_binary?(term, target) when is_map(term),
    do:
      term
      |> Map.to_list()
      |> Enum.any?(fn {key, value} ->
        contains_exact_binary?(key, target) or contains_exact_binary?(value, target)
      end)

  defp contains_exact_binary?(_term, _target), do: false

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
