defmodule Arbor.Orchestrator.AgentTurnE2ETest do
  @moduledoc """
  End-to-end baseline for agent turn behavior, and a regression guard.

  Exercises a real Session through full turns (`send_message` → preprocessor →
  build_turn_values → Engine.run → response), with a deterministic mocked LLM
  adapter and a simulated turn DOT.

  Three layers:

    * **baseline** (`:integration`, deterministic) — current agent turn behavior
      with the preprocessor OFF (the production default). This is the regression
      guard: if a future Arbor change breaks the turn pipeline, these fail.

    * **preprocessor fail-open** (`:integration`, deterministic) — enables the
      preprocessor but points it at a dead port. Proves the critical safety
      invariant: a preprocessor failure can NEVER break a turn (it fails open and
      the turn completes with the identical shape).

    * **preprocessor live** (`:llm_local`, on demand) — uses a *real* turn DOT
      (`real_turn_path`): `send_message` makes an actual LLM call through LlmHandler
      (gemma via LM Studio), not a simulated node. Asserts turns complete, the
      classifier produces a sane tier, and the `[:arbor, :llm, :call]` span fires.
      Needs LM Studio + Ollama running; excluded from default/CI runs.

  Run:
      mix test --only integration   # baseline + fail-open (no external deps)
      mix test --only llm_local      # live preprocessor (needs Ollama + LM Studio)
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.{Preprocessor, Session}
  alias Arbor.Orchestrator.UnifiedLLM.Client

  @app :arbor_orchestrator

  setup_all do
    case Elixir.Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "arbor_e2e_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    turn_dot = """
    digraph Turn {
      graph [goal="E2E turn"]
      start [shape=Mdiamond]
      classify [type="compute", simulate="true"]
      call_llm [type="compute", simulate="true"]
      done [shape=Msquare]
      start -> classify -> call_llm -> done
    }
    """

    heartbeat_dot = """
    digraph Heartbeat {
      graph [goal="E2E heartbeat"]
      start [shape=Mdiamond]
      select_mode [type="compute", simulate="true"]
      done [shape=Msquare]
      start -> select_mode -> done
    }
    """

    # Real turn DOT for the :llm_local block — a single compute node that makes an
    # actual LLM call (simulate="false") on the user message, then copies the response
    # into session.response. Exercises LlmHandler.call_llm_and_respond → the
    # [:arbor, :llm, :call] telemetry span end-to-end. gemma-4-e4b is a general LLM
    # (we use it for the needs_tools gate, but it serves a turn fine), routed via the
    # lm_studio adapter (default base_url http://localhost:1234/v1).
    real_turn_dot = """
    digraph RealTurn {
      graph [goal="E2E live turn"]
      start [shape=Mdiamond]
      call_llm [
        type="compute",
        simulate="false",
        prompt_context_key="session.input",
        llm_provider="lm_studio",
        llm_model="gemma-4-e4b-it@q4_k_xl",
        use_tools="false"
      ]
      format [
        type="transform",
        transform="identity",
        source_key="last_response",
        output_key="session.response"
      ]
      done [shape=Msquare]
      start -> call_llm -> format -> done
    }
    """

    turn_path = Path.join(tmp, "turn.dot")
    heartbeat_path = Path.join(tmp, "heartbeat.dot")
    real_turn_path = Path.join(tmp, "turn_real.dot")
    File.write!(turn_path, turn_dot)
    File.write!(heartbeat_path, heartbeat_dot)
    File.write!(real_turn_path, real_turn_dot)

    # Deterministic LLM adapter — numbered responses, no external calls.
    counter = :counters.new(1, [:atomics])

    adapters = %{
      llm_call: fn _messages, _mode, _opts ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        {:ok, %{content: "response #{n}"}}
      end
    }

    # Save/restore preprocessor config so suites don't leak.
    orig_enabled = Application.get_env(@app, :preprocessor_enabled, false)
    orig_cfg = Application.get_env(@app, :preprocessor)

    on_exit(fn ->
      Application.put_env(@app, :preprocessor_enabled, orig_enabled)
      if orig_cfg, do: Application.put_env(@app, :preprocessor, orig_cfg)
      File.rm_rf(tmp)
    end)

    # Grant the orchestrator capability for our test agent (mandatory middleware
    # gates send_message on arbor://orchestrator/execute).
    Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access("agent_e2e_test")

    %{
      turn_path: turn_path,
      heartbeat_path: heartbeat_path,
      real_turn_path: real_turn_path,
      adapters: adapters
    }
  end

  defp start_session(ctx, overrides \\ []) do
    id = "e2e-#{:erlang.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          session_id: id,
          agent_id: "agent_e2e_test",
          trust_tier: :established,
          turn_dot: ctx.turn_path,
          heartbeat_dot: ctx.heartbeat_path,
          adapters: ctx.adapters,
          start_heartbeat: false
        ],
        overrides
      )

    {:ok, pid} = Session.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, pid}
  end

  # ── BASELINE: current agent turn behavior (preprocessor OFF) ──────────────
  describe "agent turn baseline [preprocessor disabled]" do
    @describetag :integration

    setup do
      Application.put_env(@app, :preprocessor_enabled, false)
      :ok
    end

    test "a single turn completes and returns the expected response shape", ctx do
      {:ok, pid} = start_session(ctx)

      assert {:ok, response} = Session.send_message(pid, "hello, what can you do?")
      assert is_binary(response.content)
      assert is_list(response.tool_history)
      assert is_integer(response.tool_rounds)
    end

    test "a multi-turn conversation keeps the session alive across turns", ctx do
      {:ok, pid} = start_session(ctx)

      for msg <- ["first message", "second message", "third message"] do
        assert {:ok, response} = Session.send_message(pid, msg)
        assert is_binary(response.content)
      end

      # session still responsive after multiple turns
      assert %{} = Session.get_state(pid)
    end

    test "an empty/edge-case message still returns a well-formed result", ctx do
      {:ok, pid} = start_session(ctx)
      assert {:ok, response} = Session.send_message(pid, "ok")
      assert is_binary(response.content)
    end

    test "a completed turn emits the [:arbor, :session, :turn] telemetry event", ctx do
      {:ok, pid} = start_session(ctx)

      ref = make_ref()
      parent = self()
      handler_id = "e2e-turn-telemetry-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:arbor, :session, :turn],
        fn _event, measurements, metadata, _config ->
          send(parent, {ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _response} = Session.send_message(pid, "hello")

      assert_receive {^ref, measurements, metadata}, 5_000
      # duration is native time units (System.monotonic_time delta) — positive
      assert is_integer(measurements.duration) and measurements.duration > 0
      assert metadata.status == :ok
      assert metadata.agent_id == "agent_e2e_test"
    end
  end

  # ── PREPROCESSOR FAIL-OPEN: a preprocessor failure never breaks a turn ────
  describe "preprocessor fail-open safety [enabled, provider unreachable]" do
    @describetag :integration

    setup do
      # Enabled, but every stage points at a dead port → connection refused (fast).
      Application.put_env(@app, :preprocessor_enabled, true)

      Application.put_env(@app, :preprocessor,
        needs_tools: [provider: :lm_studio, model: "x", base_url: "http://localhost:9/v1"],
        complexity: [provider: :ollama, model: "x", base_url: "http://localhost:9"],
        intent: [provider: :ollama, model: "x"],
        # point gateway modules at a non-existent module so they're treated as unavailable
        prompt_classifier: Arbor.Orchestrator.NoSuchModule,
        intent_extractor: Arbor.Orchestrator.NoSuchModule,
        timeout_ms: 2_000
      )

      :ok
    end

    test "turn completes with the identical shape even when the preprocessor can't reach its providers",
         ctx do
      {:ok, pid} = start_session(ctx)

      assert {:ok, response} = Session.send_message(pid, "delete the old logs and commit")
      assert is_binary(response.content)
      assert is_list(response.tool_history)
      assert is_integer(response.tool_rounds)
    end

    test "Preprocessor.run fails open to needs_tools=true (fail-safe) when the gate provider is down" do
      # needs_tools fails SAFE (true) so a dead gate never wrongly routes to the
      # no-tools DIRECT fast lane.
      {:ok, out} = Preprocessor.run("commit this change")
      assert out["needs_tools"] == true
      assert out["tier"] in ["STANDARD", "DEEP"]
    end
  end

  # ── PREPROCESSOR LIVE: real local models, REAL turns (on demand) ──────────
  # Uses the real turn DOT (ctx.real_turn_path) so send_message makes an actual LLM
  # call through LlmHandler — not the simulated baseline DOT. Needs LM Studio (gemma,
  # the turn + needs_tools gate) and Ollama (granite, complexity) running.
  describe "preprocessor live [real local models]" do
    @describetag :llm_local
    @describetag timeout: 120_000

    setup do
      Application.put_env(@app, :preprocessor_enabled, true)
      # Uses the default :preprocessor config (gemma via LM Studio, granite via Ollama).
      Application.delete_env(@app, :preprocessor)

      # The default test suite disables local provider discovery
      # (config/test.exs: discover_local_providers: false), so the shared Client has
      # no lm_studio/ollama adapter and turns would fail with {:unknown_provider, ...}.
      # The live block DOES want local providers — install a local-discovering Client
      # for the turn path, restore the previous one afterward.
      prev_client = Client.default_client()
      Client.set_default_client(Client.from_env(discover_local: true))
      on_exit(fn -> Client.set_default_client(prev_client) end)

      :ok
    end

    test "a tool-needing prompt classifies to a non-DIRECT tier and the turn completes", ctx do
      {:ok, pid} = start_session(ctx, turn_dot: ctx.real_turn_path)

      {:ok, out} = Preprocessor.run("add a new roadmap item for the voice work and commit it")
      assert out["needs_tools"] == true
      assert out["tier"] in ["STANDARD", "DEEP"]

      assert {:ok, response} = Session.send_message(pid, "add a new roadmap item and commit it")
      assert is_binary(response.content)
      assert response.content != ""
    end

    test "a conversational prompt classifies DIRECT and the turn completes", ctx do
      {:ok, pid} = start_session(ctx, turn_dot: ctx.real_turn_path)

      {:ok, out} = Preprocessor.run("what do you think of this approach?")
      assert out["needs_tools"] == false
      assert out["tier"] == "DIRECT"

      assert {:ok, response} = Session.send_message(pid, "what do you think of this approach?")
      assert is_binary(response.content)
    end

    test "a real turn emits the [:arbor, :llm, :call] telemetry span", ctx do
      {:ok, pid} = start_session(ctx, turn_dot: ctx.real_turn_path)

      ref = make_ref()
      parent = self()
      handler_id = "e2e-llm-call-telemetry-#{:erlang.unique_integer([:positive])}"

      # The preprocessor's own LLM calls go through direct Req (not the Client), so
      # they don't emit this event — only the turn's LlmHandler call does.
      :telemetry.attach(
        handler_id,
        [:arbor, :llm, :call, :stop],
        fn _event, measurements, metadata, _config ->
          send(parent, {ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, response} = Session.send_message(pid, "Reply with a single word.")
      assert is_binary(response.content)

      assert_receive {^ref, measurements, metadata}, 60_000
      assert is_integer(measurements.duration) and measurements.duration > 0
      assert metadata.node_id == "call_llm"
      assert metadata.result == :ok
    end
  end
end
