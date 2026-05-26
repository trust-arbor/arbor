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

    * **preprocessor live** (`:llm_local`, on demand) — enables the preprocessor
      against real local models; asserts turns still complete and the classifier
      produces a sane tier. Excluded from default/CI runs.

  Run:
      mix test --only integration   # baseline + fail-open (no external deps)
      mix test --only llm_local      # live preprocessor (needs Ollama + LM Studio)
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.{Preprocessor, Session}

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

    turn_path = Path.join(tmp, "turn.dot")
    heartbeat_path = Path.join(tmp, "heartbeat.dot")
    File.write!(turn_path, turn_dot)
    File.write!(heartbeat_path, heartbeat_dot)

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

    %{turn_path: turn_path, heartbeat_path: heartbeat_path, adapters: adapters}
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

  # ── PREPROCESSOR LIVE: real local models (on demand) ──────────────────────
  describe "preprocessor live [real local models]" do
    @describetag :llm_local
    @describetag timeout: 120_000

    setup do
      Application.put_env(@app, :preprocessor_enabled, true)
      # Uses the default :preprocessor config (gemma via LM Studio, granite via Ollama).
      Application.delete_env(@app, :preprocessor)
      :ok
    end

    test "a tool-needing prompt classifies to a non-DIRECT tier and the turn completes", ctx do
      {:ok, pid} = start_session(ctx)

      {:ok, out} = Preprocessor.run("add a new roadmap item for the voice work and commit it")
      assert out["needs_tools"] == true
      assert out["tier"] in ["STANDARD", "DEEP"]

      assert {:ok, response} = Session.send_message(pid, "add a new roadmap item and commit it")
      assert is_binary(response.content)
    end

    test "a conversational prompt classifies DIRECT and the turn completes", ctx do
      {:ok, pid} = start_session(ctx)

      {:ok, out} = Preprocessor.run("what do you think of this approach?")
      assert out["needs_tools"] == false
      assert out["tier"] == "DIRECT"

      assert {:ok, response} = Session.send_message(pid, "what do you think of this approach?")
      assert is_binary(response.content)
    end
  end
end
