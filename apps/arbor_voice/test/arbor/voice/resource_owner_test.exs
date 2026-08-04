defmodule Arbor.Voice.ResourceOwnerTest do
  use ExUnit.Case, async: false

  alias Arbor.Voice.BackendWorker
  alias Arbor.Voice.ResourceOwner
  alias Arbor.Voice.Test.ResourceOwnerBackend, as: Backend

  @moduletag :fast

  @default_opts [
    close_timeout_ms: 1_000,
    cleanup_ready_timeout_ms: 200,
    cleanup_attempts: 2,
    cleanup_per_attempt_timeout_ms: 100,
    max_recv_timeout_ms: 500
  ]

  @route %{
    destination: "api.x.ai",
    provider: "xai",
    runtime: "arbor",
    model: "grok-voice-latest"
  }

  defmodule ConfigureLatestBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    def egress_route, do: :none
    def open(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent), generation: 0}}

    def configure(session, _config),
      do: {:error, :distinctive_failure, %{session | generation: 1}}

    def send_text(session, _text), do: {:ok, session}
    def send_audio(session, _chunk), do: {:ok, session}

    def send_tool_result(session, _call_id, _output), do: {:ok, session}
    def recv(_session, _timeout), do: {:error, :timeout}

    def close(session) do
      send(session.parent, {:configure_latest_closed, session.generation, self()})
      :ok
    end

    def meta(_session),
      do: %{backend: :configure_latest, mode: :local, input_rate: nil, output_rate: nil}
  end

  defmodule BadMetaBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    def egress_route, do: :none
    def open(_opts), do: {:ok, %{}}
    def configure(session, _config), do: {:ok, session}
    def send_text(session, _text), do: {:ok, session}
    def send_audio(session, _chunk), do: {:ok, session}
    def send_tool_result(session, _call_id, _output), do: {:ok, session}
    def recv(session, _timeout), do: {:ok, session, {:turn_done, %{text: ""}}}
    def close(_session), do: :ok
    def meta(_session), do: %{backend: :bad, mode: :invalid}
  end

  defmodule OpenFailureBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    def egress_route, do: :none
    def open(_opts), do: {:error, :raw_secret}
    def configure(session, _config), do: {:ok, session}
    def send_text(session, _text), do: {:ok, session}
    def send_audio(session, _chunk), do: {:ok, session}
    def send_tool_result(session, _call_id, _output), do: {:ok, session}
    def recv(_session, _timeout), do: {:error, :timeout}
    def close(_session), do: :ok

    def meta(_session),
      do: %{backend: :open_failure, mode: :local, input_rate: nil, output_rate: nil}
  end

  defmodule TimeoutBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    def egress_route, do: :none
    def open(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent)}}
    def configure(session, _config), do: {:ok, session}

    def send_text(session, _text) do
      Process.sleep(250)
      {:ok, session}
    end

    def send_audio(session, _chunk), do: {:ok, session}

    def send_tool_result(session, _call_id, _output) do
      Process.sleep(250)
      {:ok, session}
    end

    def recv(_session, _timeout), do: {:error, :timeout}

    def close(session) do
      send(session.parent, {:timeout_backend_closed, self()})
      :ok
    end

    def meta(_session),
      do: %{backend: :timeout, mode: :local, input_rate: nil, output_rate: nil}
  end

  defmodule ForgedCallBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    def egress_route, do: :none
    def open(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent)}}
    def configure(session, _config), do: {:ok, session}

    def send_text(session, text) do
      send(session.parent, {:forged_backend_effect, text, self()})
      {:ok, session}
    end

    def send_audio(session, _chunk), do: {:ok, session}
    def send_tool_result(session, _call_id, _output), do: {:ok, session}
    def recv(_session, _timeout), do: {:error, :timeout}
    def close(_session), do: :ok

    def meta(_session),
      do: %{backend: :forged, mode: :local, input_rate: nil, output_rate: nil}
  end

  defmodule EffectTrust do
    def authorize_egress(_agent_id, :external_provider, _opts), do: :allow
  end

  defmodule EffectSecurity do
    def authorize_source_owned_exact_ordinary_capability(
          _agent_id,
          _resource_uri,
          _effect,
          _capability_id,
          _expectations
        ),
        do: {:ok, :authorized}

    def validate_disclosure_capability(_agent_id, _capability_id, _opts), do: :ok
  end

  defmodule EffectBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    @route %{
      destination: "api.x.ai",
      provider: "xai",
      runtime: "arbor",
      model: "grok-voice-latest"
    }

    def egress_route, do: @route

    def open(opts) do
      session = %{
        parent: Keyword.fetch!(opts, :parent),
        authorize: Keyword.fetch!(opts, :effect_authorizer),
        wrong_on: Keyword.get(opts, :wrong_on)
      }

      with :ok <- effects(session, :open, [:connect]) do
        {:ok, session}
      end
    end

    def configure(session, _config), do: operation(session, :configure, [:configure])

    def send_text(session, _text),
      do: operation(session, :send_text, [:text_item, :text_response])

    def send_audio(session, _chunk),
      do: operation(session, :send_audio, [:audio_append, :audio_commit, :audio_response])

    def send_tool_result(session, _call_id, _output),
      do: operation(session, :send_tool_result, [:tool_result_item, :tool_result_response])

    def recv(session, _timeout), do: {:ok, session, {:turn_done, %{text: ""}}}

    def close(session) do
      send(session.parent, {:effect_backend_closed, self()})
      :ok
    end

    def meta(_session),
      do: %{backend: :effect, mode: :cloud, input_rate: 16_000, output_rate: 24_000}

    defp operation(session, operation, expected) do
      effects =
        if session.wrong_on == operation,
          do: Enum.reverse(expected),
          else: expected

      case effects(session, operation, effects) do
        :ok -> {:ok, session}
        {:error, reason} -> {:error, reason, session}
      end
    end

    defp effects(session, operation, effects) do
      Enum.reduce_while(effects, :ok, fn effect, :ok ->
        case session.authorize.(effect, @route) do
          :allow ->
            send(session.parent, {:physical_effect, operation, effect, self()})
            {:cont, :ok}

          _denied ->
            {:halt, {:error, :denied}}
        end
      end)
    end
  end

  setup do
    :ok = Backend.start_test_table!()
    assert is_pid(Process.whereis(Arbor.Voice.ResourceSupervisor))
    assert is_pid(Process.whereis(Arbor.Voice.BackendWorkerSupervisor))
    assert is_pid(Process.whereis(Arbor.Voice.CleanupLeaseSupervisor))
    :ok
  end

  @tag spec: "VOICE-5"
  test "persistent worker forwards callbacks and preserves admitted tool-result then close order" do
    assert {:ok, owner} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)

    initial = Backend.session_handle(self())
    assert :ok = ResourceOwner.configure(owner, %{instructions: "hello"})
    configured = Backend.session_handle(self())
    refute initial == configured

    assert :ok = ResourceOwner.send_text(owner, "text")
    after_text = Backend.session_handle(self())
    refute configured == after_text

    assert :ok = ResourceOwner.send_audio(owner, <<1, 2, 3>>)

    assert {:ok, first_request} =
             ResourceOwner.send_tool_result_request(owner, "call-1", "output-1")

    assert {:ok, second_request} =
             ResourceOwner.send_tool_result_request(owner, "call-2", "output-2")

    assert :ok = ResourceOwner.close(owner)
    assert {:reply, :ok} = :gen_server.wait_response(first_request, 100)
    assert {:reply, :ok} = :gen_server.wait_response(second_request, 100)
    assert Backend.close_count(self()) == 1
    refute Process.alive?(owner)
    assert {:error, :owner_unavailable} = ResourceOwner.close(owner)
  end

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "configure partial failure closes the latest handle and becomes terminal" do
    assert {:ok, owner} =
             ResourceOwner.start(self(), ConfigureLatestBackend, [parent: self()], @default_opts)

    assert {:error, :backend_callback_failed} = ResourceOwner.configure(owner, %{})
    assert_receive {:configure_latest_closed, 1, worker}, 500
    refute worker == owner
    refute_receive {:configure_latest_closed, 0, _worker}, 50
    assert %{worker: nil, poisoned: true, phase: :terminal} = :sys.get_state(owner)
    assert {:error, :owner_poisoned} = ResourceOwner.meta(owner)
    assert :ok = ResourceOwner.close(owner)
  end

  @tag :security_regression
  test "malformed metadata retires the worker before returning" do
    assert {:ok, owner} = ResourceOwner.start(self(), BadMetaBackend, [], @default_opts)
    assert {:error, :invalid_backend_meta} = ResourceOwner.meta(owner)
    assert %{worker: nil, poisoned: true, phase: :terminal} = :sys.get_state(owner)
    assert :ok = ResourceOwner.close(owner)
  end

  @tag :security_regression
  test "foreign public callers have no owner token" do
    test_pid = self()
    assert {:ok, owner} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)

    spawn(fn ->
      results = [
        ResourceOwner.configure(owner, %{}),
        ResourceOwner.send_text(owner, "x"),
        ResourceOwner.send_audio(owner, <<>>),
        ResourceOwner.send_tool_result(owner, "x", "y"),
        ResourceOwner.recv(owner, 10),
        ResourceOwner.meta(owner),
        ResourceOwner.register_cleanup(owner, :x, fn -> :ok end),
        ResourceOwner.adopt_provisional_cleanup(owner, :x, fn -> :ok end),
        ResourceOwner.remove_cleanup(owner, :x),
        ResourceOwner.close(owner)
      ]

      send(test_pid, {:foreign_results, results})
    end)

    assert_receive {:foreign_results, results}, 500
    assert Enum.all?(results, &(&1 == {:error, :foreign_caller}))
    assert :ok = ResourceOwner.close(owner)
  end

  @tag :security_regression
  test "security regression: forged GenServer from tuple cannot execute backend work" do
    actual_owner = self()

    assert {:ok, resource_owner} =
             ResourceOwner.start(actual_owner, ForgedCallBackend, [parent: self()], @default_opts)

    attacker =
      spawn(fn ->
        forged_tag = make_ref()

        send(
          resource_owner,
          {:"$gen_call", {actual_owner, forged_tag}, {:backend, :send_text, ["forged"]}}
        )
      end)

    attacker_ref = Process.monitor(attacker)
    assert_receive {:DOWN, ^attacker_ref, :process, ^attacker, :normal}, 500
    refute_receive {:forged_backend_effect, "forged", _worker}, 150
    assert :ok = ResourceOwner.send_text(resource_owner, "authentic")
    assert_receive {:forged_backend_effect, "authentic", worker}, 500
    refute worker == resource_owner
    assert :ok = ResourceOwner.close(resource_owner)
  end

  test "start preserves detailed preflight errors and marks post-handoff open failure" do
    assert {:error, :invalid_backend} =
             ResourceOwner.start(self(), String, [], @default_opts)

    assert {:error, {:invalid_owner_config, :backend_opts}} =
             ResourceOwner.start(self(), Backend, [parent: self(), parent: self()], @default_opts)

    assert {:error, {:invalid_owner_config, :close_timeout_ms}} =
             ResourceOwner.start(self(), Backend, [parent: self()], close_timeout_ms: 0)

    assert {:error, :invalid_authority} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: self()],
               %{authority: local_authority(), initial_cleanup: nil, initial_cleanups: %{}},
               @default_opts
             )

    assert {:error, :invalid_authority} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: self()],
               %{
                 authority: local_authority(),
                 initial_cleanups: %{{:voice_provisional_cleanup, :reserved} => fn -> :ok end}
               },
               @default_opts
             )

    assert {:error, {:handoff_accepted, :start_failed}} =
             ResourceOwner.start(self(), OpenFailureBackend, [], @default_opts)
  end

  test "legacy and canonical cleanup handoffs are accepted while ambiguous forms fail closed" do
    test_pid = self()

    legacy = %{
      authority: local_authority(),
      initial_cleanup: {:legacy, notify_cleanup(test_pid, :legacy)}
    }

    assert {:ok, legacy_owner} =
             ResourceOwner.start(self(), Backend, [parent: self()], legacy, @default_opts)

    assert :ok = ResourceOwner.close(legacy_owner)
    assert_receive {:cleanup, :legacy, cleanup_pid}, 500
    refute cleanup_pid == legacy_owner

    canonical = %{
      authority: local_authority(),
      initial_cleanups: %{
        first: notify_cleanup(test_pid, :first),
        second: notify_cleanup(test_pid, :second)
      }
    }

    assert {:ok, canonical_owner} =
             ResourceOwner.start(self(), Backend, [parent: self()], canonical, @default_opts)

    assert :ok = ResourceOwner.close(canonical_owner)
    assert_receive {:cleanup, :first, _pid}, 500
    assert_receive {:cleanup, :second, _pid}, 500
  end

  test "cleanup registration, provisional adoption, removal, duplicates, and capacity delegate to lease" do
    opts = Keyword.put(@default_opts, :max_cleanups, 2)
    assert {:ok, owner} = ResourceOwner.start(self(), Backend, [parent: self()], opts)
    cleanup = fn -> :ok end

    assert :ok = ResourceOwner.register_cleanup(owner, :one, cleanup)
    assert {:error, :duplicate_cleanup_key} = ResourceOwner.register_cleanup(owner, :one, cleanup)
    assert :ok = ResourceOwner.register_cleanup(owner, :two, cleanup)

    assert {:error, :cleanup_capacity_exceeded} =
             ResourceOwner.register_cleanup(owner, :three, cleanup)

    assert :ok = ResourceOwner.adopt_provisional_cleanup(owner, :provisional, cleanup)
    assert :ok = ResourceOwner.adopt_provisional_cleanup(owner, :provisional, cleanup)

    assert {:error, :provisional_cleanup_occupied} =
             ResourceOwner.adopt_provisional_cleanup(owner, :other, cleanup)

    assert :ok = ResourceOwner.remove_cleanup(owner, :one)
    assert {:error, :unknown_cleanup_key} = ResourceOwner.remove_cleanup(owner, :one)
    assert :ok = ResourceOwner.close(owner)
  end

  @tag :security_regression
  test "close reports cleanup_pending while the independent lease retains failed work" do
    test_pid = self()
    {:ok, gate} = Agent.start_link(fn -> :fail end)

    cleanup = fn ->
      case Agent.get(gate, & &1) do
        :fail ->
          {:error, :retry}

        :pass ->
          send(test_pid, {:retained_cleanup_succeeded, self()})
          :ok
      end
    end

    opts =
      @default_opts
      |> Keyword.put(:close_timeout_ms, 150)
      |> Keyword.put(:cleanup_per_attempt_timeout_ms, 30)

    assert {:ok, owner} = ResourceOwner.start(self(), Backend, [parent: self()], opts)
    assert :ok = ResourceOwner.register_cleanup(owner, :retained, cleanup)
    assert {:error, :cleanup_pending} = ResourceOwner.close(owner)
    refute Process.alive?(owner)

    Agent.update(gate, fn _ -> :pass end)
    assert_receive {:retained_cleanup_succeeded, cleanup_pid}, 1_500
    refute cleanup_pid == owner
  end

  @tag :security_regression
  test "owner death closes through the worker and drains through the lease" do
    test_pid = self()

    owner_pid =
      spawn(fn ->
        {:ok, resource_owner} =
          ResourceOwner.start(self(), Backend, [parent: test_pid], @default_opts)

        :ok =
          ResourceOwner.register_cleanup(resource_owner, :owner_death, fn ->
            send(test_pid, {:owner_death_cleanup, self()})
            :ok
          end)

        send(test_pid, {:owner_ready, self(), resource_owner})
        receive do: (:die -> :ok)
      end)

    assert_receive {:owner_ready, ^owner_pid, resource_owner}, 500
    owner_ref = Process.monitor(owner_pid)
    resource_ref = Process.monitor(resource_owner)
    send(owner_pid, :die)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}, 500
    assert_receive {:resource_owner_backend_close, _id, 1}, 1_000
    assert_receive {:owner_death_cleanup, cleanup_pid}, 1_000
    refute cleanup_pid == resource_owner
    assert_receive {:DOWN, ^resource_ref, :process, ^resource_owner, :normal}, 1_000
  end

  @tag :security_regression
  test "operation timeout retires the exact worker before returning and prevents reuse" do
    opts = Keyword.put(@default_opts, :close_timeout_ms, 100)

    assert {:ok, owner} =
             ResourceOwner.start(self(), TimeoutBackend, [parent: self()], opts)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :owner_timeout} = ResourceOwner.send_text(owner, "slow")
    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 1_000
    assert %{worker: nil, phase: :terminal} = :sys.get_state(owner)
    assert {:error, :owner_poisoned} = ResourceOwner.meta(owner)
    assert :ok = ResourceOwner.close(owner)
  end

  @tag :security_regression
  test "tampered worker effect request poisons the active operation and waits for worker down" do
    alias Arbor.Voice.BackendWorker.EffectRequest
    alias Arbor.Voice.Redacted

    opts = Keyword.put(@default_opts, :close_timeout_ms, 100)

    assert {:ok, owner} =
             ResourceOwner.start(self(), TimeoutBackend, [parent: self()], opts)

    assert {:ok, request_id} =
             ResourceOwner.send_tool_result_request(owner, "call", "sensitive output")

    assert %{worker: worker, current: current} = :sys.get_state(owner)

    tampered = %EffectRequest{
      worker: worker,
      coordinator: owner,
      generation: make_ref(),
      operation_token: current.token,
      effect_token: make_ref(),
      effect: :tool_result_item,
      frozen_route: :none,
      reply_alias: make_ref(),
      authenticator: Redacted.new("forged")
    }

    send(owner, tampered)

    assert {:reply, {:error, :backend_effect_denied}} =
             :gen_server.wait_response(request_id, 500)

    assert %{worker: nil, poisoned: true, phase: :terminal} = :sys.get_state(owner)
    assert :ok = ResourceOwner.close(owner)
  end

  test "planned supervisor shutdown leaves cleanup execution to the independent lease" do
    test_pid = self()
    assert {:ok, owner} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)

    assert :ok =
             ResourceOwner.register_cleanup(owner, :planned_shutdown, fn ->
               send(test_pid, {:planned_shutdown_cleanup, self()})
               :ok
             end)

    owner_ref = Process.monitor(owner)
    assert :ok = DynamicSupervisor.terminate_child(Arbor.Voice.ResourceSupervisor, owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :shutdown}, 500
    assert_receive {:planned_shutdown_cleanup, cleanup_pid}, 1_000
    refute cleanup_pid == owner
  end

  @tag :security_regression
  test "external effects are authenticated and authorized in exact operation order" do
    test_pid = self()
    handoff = external_handoff(test_pid)

    assert {:ok, owner} =
             ResourceOwner.start(self(), EffectBackend, [parent: self()], handoff, @default_opts)

    assert_receive {:physical_effect, :open, :connect, worker}, 500
    refute worker == owner
    assert :ok = ResourceOwner.configure(owner, %{})
    assert_receive {:physical_effect, :configure, :configure, ^worker}, 500

    {turn_id, turn_lease, cleanup_key} = external_turn()

    assert :ok =
             ResourceOwner.register_cleanup(owner, cleanup_key, fn ->
               send(test_pid, {:turn_cleanup, self()})
               :ok
             end)

    assert :ok = ResourceOwner.activate_turn(owner, turn_lease)
    assert :ok = ResourceOwner.send_text(owner, "hello")
    assert_receive {:physical_effect, :send_text, :text_item, ^worker}, 500
    assert_receive {:physical_effect, :send_text, :text_response, ^worker}, 500
    assert :ok = ResourceOwner.fence_and_drain(owner, turn_id)
    assert_receive {:turn_cleanup, cleanup_pid}, 500
    refute cleanup_pid == owner
    assert :ok = ResourceOwner.close(owner)
    assert_receive {:route_cleanup, route_cleanup_pid}, 500
    refute route_cleanup_pid == owner
  end

  @tag :security_regression
  test "wrong effect order is denied, poisons the resource, and permits no reuse" do
    test_pid = self()

    assert {:ok, owner} =
             ResourceOwner.start(
               self(),
               EffectBackend,
               [parent: self(), wrong_on: :send_text],
               external_handoff(test_pid),
               @default_opts
             )

    assert_receive {:physical_effect, :open, :connect, _worker}, 500
    assert :ok = ResourceOwner.configure(owner, %{})
    assert_receive {:physical_effect, :configure, :configure, _worker}, 500
    {_turn_id, turn_lease, cleanup_key} = external_turn()
    assert :ok = ResourceOwner.register_cleanup(owner, cleanup_key, fn -> :ok end)
    assert :ok = ResourceOwner.activate_turn(owner, turn_lease)

    assert {:error, :backend_effect_denied} = ResourceOwner.send_text(owner, "blocked")
    refute_receive {:physical_effect, :send_text, _effect, _worker}, 100
    assert %{worker: nil, poisoned: true, phase: :terminal} = :sys.get_state(owner)
    assert {:error, :owner_poisoned} = ResourceOwner.send_audio(owner, <<1>>)
    assert :ok = ResourceOwner.close(owner)
  end

  test "turn cleanup settlement is asynchronous and keeps the owner mailbox responsive" do
    test_pid = self()
    assert {:ok, owner} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)
    turn_id = "turn_" <> String.duplicate("d", 32)
    key = {:voice_turn, turn_id}

    coordinator =
      spawn(fn ->
        receive do
          {:settlement_started, cleanup_pid} ->
            foreign_result = ResourceOwner.meta(owner)
            send(test_pid, {:foreign_during_cleanup, foreign_result})
            send(cleanup_pid, :release)
        end
      end)

    cleanup = fn ->
      send(coordinator, {:settlement_started, self()})

      receive do
        :release ->
          send(test_pid, :settlement_released)
          :ok
      end
    end

    assert :ok = ResourceOwner.register_cleanup(owner, key, cleanup)

    assert :ok =
             ResourceOwner.activate_turn(owner, %{
               kind: :local,
               turn_id: turn_id,
               cleanup_key: key
             })

    assert is_pid(coordinator)
    assert :ok = ResourceOwner.fence_and_drain(owner, turn_id)
    assert_receive {:foreign_during_cleanup, {:error, :foreign_caller}}, 500
    assert_receive :settlement_released, 500
    assert :ok = ResourceOwner.close(owner)
  end

  test "bounds fail closed without exposing or poisoning a reusable owner" do
    oversized_opts = [secret: String.duplicate("s", 70_000)]

    assert {:error, {:invalid_owner_config, :backend_opts}} =
             ResourceOwner.start(self(), Backend, oversized_opts, @default_opts)

    oversized_cleanups =
      for index <- 1..17, into: %{}, do: {index, fn -> :ok end}

    assert {:error, :invalid_authority} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: self()],
               %{authority: local_authority(), initial_cleanups: oversized_cleanups},
               @default_opts
             )

    assert {:ok, owner} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)

    oversized_audio = :binary.copy(<<0>>, BackendWorker.max_audio_bytes() + 1)
    assert {:error, :backend_callback_failed} = ResourceOwner.send_audio(owner, oversized_audio)
    assert {:ok, %{backend: :resource_owner_backend}} = ResourceOwner.meta(owner)

    oversized_key = String.duplicate("k", 5_000)

    assert {:error, :invalid_cleanup} =
             ResourceOwner.register_cleanup(owner, oversized_key, fn -> :ok end)

    assert :ok = ResourceOwner.close(owner)
  end

  @tag :security_regression
  test "status, state inspection, messages, and errors redact authority and closure secrets" do
    backend_secret = "backend-secret-that-must-not-leak"
    cleanup_secret = "cleanup-secret-that-must-not-leak"
    token_before = inspect(Process.get())

    handoff = %{
      authority: local_authority(),
      initial_cleanups: %{
        cleanup: fn ->
          _captured = cleanup_secret
          :ok
        end
      }
    }

    assert {:ok, owner} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: self(), secret: backend_secret],
               handoff,
               @default_opts
             )

    inspections = [
      inspect(:sys.get_state(owner)),
      inspect(:sys.get_status(owner)),
      inspect(Process.info(owner, :messages)),
      inspect(Process.get())
    ]

    Enum.each(inspections, fn inspection ->
      refute inspection =~ backend_secret
      refute inspection =~ cleanup_secret
      refute inspection =~ "effect_authorizer"
    end)

    refute token_before =~ backend_secret

    assert {:error, :backend_callback_failed} =
             ResourceOwner.send_text(owner, String.duplicate("x", 9_000))

    assert :ok = ResourceOwner.close(owner)
  end

  defp local_authority do
    %{
      kind: :local,
      route: :none,
      session_id: "session_" <> String.duplicate("a", 32)
    }
  end

  defp external_handoff(test_pid) do
    session_id = "session_" <> String.duplicate("b", 32)

    authority = %{
      kind: :external,
      route: @route,
      tier: :external_provider,
      agent_id: "agent_test",
      human_id: "human_test",
      session_id: session_id,
      resource_uri: "arbor://voice/realtime/xai/" <> session_id,
      route_capability_id: "cap_" <> String.duplicate("c", 32),
      security_module: EffectSecurity,
      trust_module: EffectTrust
    }

    %{
      authority: authority,
      initial_cleanups: %{
        voice_realtime_route_capability: fn ->
          send(test_pid, {:route_cleanup, self()})
          :ok
        end
      }
    }
  end

  defp external_turn do
    turn_id = "turn_" <> String.duplicate("d", 32)
    cleanup_key = {:voice_turn, turn_id}

    lease = %{
      kind: :external,
      turn_id: turn_id,
      disclosure_capability_id: "cap_" <> String.duplicate("e", 32),
      cleanup_key: cleanup_key
    }

    {turn_id, lease, cleanup_key}
  end

  defp notify_cleanup(test_pid, marker) do
    fn ->
      send(test_pid, {:cleanup, marker, self()})
      :ok
    end
  end
end
