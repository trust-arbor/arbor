defmodule Arbor.Orchestrator.Handlers.LlmHandlerPhaseETest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.AI.LLMError
  alias Arbor.AI.RouteFailureStore
  alias Arbor.LLM.OAuth.ResponsesFailure
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Handlers.LlmHandler

  @moduletag :fast

  defmodule FailingControlPlaneDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    @impl true
    def dispatch(_request, _opts) do
      {:error,
       ResponsesFailure.exception(
         route: :openai_oauth,
         backend: :openai,
         code: :unauthorized,
         status: 401
       )}
    end
  end

  setup do
    prior_dispatcher = Application.get_env(:arbor_orchestrator, :llm_dispatcher)
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, FailingControlPlaneDispatcher)

    # Enter each test with a live store when a prior module leaked. Restoration
    # on exit is strict and must fail visibly if the supervised child cannot be
    # brought back (async:false mutates global Application + AI supervision).
    ensure_route_failure_store_running()

    on_exit(fn ->
      case prior_dispatcher do
        nil -> Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
        mod -> Application.put_env(:arbor_orchestrator, :llm_dispatcher, mod)
      end

      ensure_route_failure_store_running()
    end)

    :ok
  end

  test "handler failure path classifies ResponsesFailure for control-plane recording" do
    # Mirrors LlmHandler: classify then record via public AI facade once.
    failure =
      ResponsesFailure.exception(
        route: :openai_oauth,
        backend: :openai,
        code: :rate_limited,
        status: 429,
        retry_after_ms: 5_000
      )

    error_info = LLMError.classify(failure)
    assert error_info.provider == :openai_oauth
    assert error_info.type == :rate_limited
    assert LLMError.control_plane_effect(error_info) == {:quota, :rate_limited}

    # Public facade boundary used by LlmHandler (QuotaTracker may lazy-start).
    assert {:ok, :recorded} = Arbor.AI.record_classified_llm_failure(error_info)
  end

  test "security regression: handler-style classify never leaks backend as route alias" do
    failure = ResponsesFailure.transport(nil, :openai, :connection_failed)
    info = LLMError.classify(failure)
    assert info.provider == nil
    assert {:ok, :noop} = Arbor.AI.record_classified_llm_failure(info)
  end

  test "handler boundary emits bounded warning when control-plane record fails without changing LLM fail outcome" do
    # RouteFailureStore never lazy-starts. Ensure it is down so a required
    # route-failure write fails closed with a typed facade error.
    stop_route_failure_store()
    assert Process.whereis(RouteFailureStore) == nil

    # Match dispatcher-test node/graph shape so we hit the real failure path
    # without route-assembly profile requirements.
    node = %{
      id: "phase_e_cp_fail",
      attrs: %{
        "simulate" => "false",
        "prompt" => "SECRET_PROMPT_MUST_NOT_APPEAR_IN_CONTROL_PLANE_WARNING",
        "llm_provider" => "openai",
        "llm_model" => "test-model"
      }
    }

    graph = %{attrs: %{"goal" => "phase-e control-plane warning"}}

    context =
      Context.new(%{
        "session.agent_id" => "agent_phase_e_cp",
        "session.llm_provider" => "openai",
        "session.llm_model" => "test-model",
        "session.llm_runtime" => :arbor
      })

    log =
      capture_log(fn ->
        outcome = LlmHandler.execute(node, context, graph, [])
        assert outcome.status == :fail
        assert is_binary(outcome.failure_reason)
        assert outcome.failure_reason =~ "LLM call failed"
      end)

    assert log =~ "control-plane record failed"
    assert log =~ "reason=route_failure_write_failed"
    assert log =~ "error_type=auth_failure"
    refute log =~ "SECRET_PROMPT_MUST_NOT_APPEAR_IN_CONTROL_PLANE_WARNING"
    refute log =~ "account_id"
    refute log =~ "/Users/"
    # Store must remain unstarted (no lazy start on write failure).
    assert Process.whereis(RouteFailureStore) == nil
    # Do not restart here — on_exit restores supervised state so later tests
    # never observe a leaked terminated RouteFailureStore.
  end

  test "restore contract: terminated RouteFailureStore restarts clean under AI supervisor" do
    stop_route_failure_store()
    assert Process.whereis(RouteFailureStore) == nil

    ensure_route_failure_store_running()

    assert is_pid(Process.whereis(RouteFailureStore))
    assert {:ok, %{}} = RouteFailureStore.snapshot_status(now: DateTime.utc_now())
  end

  defp ensure_route_failure_store_running do
    case Process.whereis(RouteFailureStore) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          :ok
        else
          restart_route_failure_store()
        end

      _ ->
        restart_route_failure_store()
    end

    assert is_pid(Process.whereis(RouteFailureStore)),
           "RouteFailureStore must be registered after restore"

    RouteFailureStore.clear_sync(:openai_oauth)
    RouteFailureStore.clear_sync(:xai_oauth)

    assert {:ok, %{}} = RouteFailureStore.snapshot_status(now: DateTime.utc_now()),
           "RouteFailureStore must be clean after restore"

    :ok
  end

  defp restart_route_failure_store do
    case Process.whereis(Arbor.AI.Supervisor) do
      sup when is_pid(sup) ->
        case Supervisor.restart_child(sup, RouteFailureStore) do
          {:ok, _pid} ->
            :ok

          {:ok, _pid, _info} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, :running} ->
            :ok

          {:error, :not_found} ->
            case Supervisor.start_child(sup, RouteFailureStore) do
              {:ok, _pid} ->
                :ok

              {:ok, _pid, _info} ->
                :ok

              {:error, {:already_started, _pid}} ->
                :ok

              other ->
                flunk("failed to start RouteFailureStore: #{inspect(other)}")
            end

          other ->
            flunk("failed to restart RouteFailureStore: #{inspect(other)}")
        end

      _ ->
        flunk("Arbor.AI.Supervisor not running; cannot restore RouteFailureStore")
    end
  end

  defp stop_route_failure_store do
    case Process.whereis(RouteFailureStore) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        # Prefer supervised terminate when registered as a child; else stop pid.
        case Process.whereis(Arbor.AI.Supervisor) do
          sup when is_pid(sup) ->
            case Supervisor.terminate_child(sup, RouteFailureStore) do
              :ok -> :ok
              {:error, :not_found} -> stop_pid(pid)
              {:error, :not_started} -> :ok
              _ -> stop_pid(pid)
            end

          _ ->
            stop_pid(pid)
        end
    end
  end

  defp stop_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> :ok
    end
  end
end
