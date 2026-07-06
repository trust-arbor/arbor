defmodule Arbor.Orchestrator.CrossSessionMemoryTest do
  @moduledoc """
  Cross-session memory-recall regression guard (commit 90450e66).

  Proves the end-to-end wiring: a fact indexed into an agent's memory in one
  session is *recalled into a LATER session's turn* and reaches the LLM input.

  The fix (90450e66) added `session.recalled_memories` to the `build_prompt`
  node's `context_keys` in `specs/pipelines/session/turn.dot`, and taught
  `SessionLlm.BuildPrompt`'s `turn` mode to inject those recalled memories as a
  leading "## Relevant memories from past sessions" system-context section.
  Before the fix, recalled memory reached only the heartbeat — the agent
  remembered while idle but forgot mid-conversation.

  This test exercises the *real production turn pipeline*
  (`specs/pipelines/session/turn.dot`): classify → recall → mode select →
  build_prompt → call_llm. It captures the messages that reach the LLM at the
  `call_llm` compute node (via a fake default `Arbor.LLM.Client` adapter) and
  asserts the planted fact is present.

  Determinism:
    * Embeddings — `embedding_service_enabled: false` forces the offline
      deterministic hash-fallback embedding (no Ollama). Hash-fallback vectors
      are all-positive, so cosine similarity runs above recall's 0.3 threshold
      and planted facts are returned.
    * LLM — a fake default Client adapter captures the request messages and
      returns a canned response (no network).

  Run:
      mix test .../cross_session_memory_test.exs --include integration
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Session

  @memory :arbor_memory

  # Distinct agents so the control test uses a never-populated memory index —
  # no cross-test residue, no index-clearing needed.
  @agent_id "agent_xsession_mem_test"
  @control_agent_id "agent_xsession_mem_control"
  @fact "the deploy passphrase is XYZZY-PLUGH-42"
  @fact_marker "XYZZY-PLUGH-42"

  # The REAL production turn pipeline — exercises the actual recall -> build_prompt
  # -> call_llm wiring (the context_keys the fix added), not a simplified fake.
  @real_turn_dot Path.expand("../../../specs/pipelines/session/turn.dot", __DIR__)

  # ── Fake LLM adapter: captures the messages that reach the LLM ────────────
  # With simulate="false" (the production call_llm node), the LlmHandler dispatches
  # through Arbor.LLM.Client.default_client() — NOT the Session `:adapters` map
  # (that legacy seam is unused for action-based DOTs). So we capture at the Client:
  # install a default client whose only adapter is this one, forwarding every
  # request's messages to the test process.
  defmodule CaptureAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "capture_xsession"

    @impl true
    def complete(%Arbor.LLM.Request{} = request, _opts) do
      case :persistent_term.get({__MODULE__, :pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:captured, request.messages})
        _ -> :ok
      end

      {:ok,
       %Arbor.LLM.Response{
         text: "ok",
         finish_reason: :stop,
         content_parts: [Arbor.LLM.ContentPart.text("ok")],
         usage: %{},
         raw: %{}
       }}
    end

    @impl true
    def stream(_request, _opts), do: {:error, :not_supported}

    @impl true
    def embed(_texts, _model, _opts), do: {:error, :not_supported}

    @impl true
    def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}
  end

  setup_all do
    case Elixir.Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # arbor_memory runs with start_children: false in the test env — bring up the
    # memory subsystem the recall/update/checkpoint actions need (mirrors the
    # bring-up in apps/arbor_actions/test/arbor/actions/memory_test.exs).
    {:ok, _} = Application.ensure_all_started(:arbor_memory)

    for table <- [
          :arbor_memory_graphs,
          :arbor_working_memory,
          :arbor_memory_proposals,
          :arbor_chat_history,
          :arbor_preferences
        ] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    children = [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events},
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ]

    for child <- children do
      Supervisor.start_child(Arbor.Memory.Supervisor, child)
    end

    :ok
  end

  setup do
    # ── Hermetic embeddings ────────────────────────────────────────────────
    orig_embed = Application.get_env(@memory, :embedding_service_enabled)
    Application.put_env(@memory, :embedding_service_enabled, false)

    # ── Fake default LLM client (captures LLM input) ───────────────────────
    prev_client = Arbor.LLM.Client.default_client()

    capture_client =
      Arbor.LLM.Client.new(default_provider: CaptureAdapter.provider())
      |> Arbor.LLM.Client.register_adapter(CaptureAdapter)

    Arbor.LLM.Client.set_default_client(capture_client)

    # Grant the mandatory orchestrator capability for both agents.
    Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(@agent_id)
    Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(@control_agent_id)

    # Trivial heartbeat DOT (unused here, but Session.start_link requires a path).
    tmp = Path.join(System.tmp_dir!(), "arbor_xsession_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    heartbeat_path = Path.join(tmp, "heartbeat.dot")

    File.write!(heartbeat_path, """
    digraph Heartbeat {
      graph [goal="xsession heartbeat"]
      start [shape=Mdiamond]
      select_mode [type="compute", simulate="true"]
      done [shape=Msquare]
      start -> select_mode -> done
    }
    """)

    on_exit(fn ->
      if orig_embed == nil do
        Application.delete_env(@memory, :embedding_service_enabled)
      else
        Application.put_env(@memory, :embedding_service_enabled, orig_embed)
      end

      Arbor.LLM.Client.set_default_client(prev_client)
      :persistent_term.erase({CaptureAdapter, :pid})
      File.rm_rf(tmp)
    end)

    %{heartbeat_path: heartbeat_path}
  end

  # Start a FRESH session (new session_id) for `agent_id` on the real turn DOT.
  defp start_fresh_session(ctx, agent_id) do
    id = "xsession-#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      Session.start_link(
        session_id: id,
        agent_id: agent_id,
        trust_tier: :established,
        turn_dot: @real_turn_dot,
        heartbeat_dot: ctx.heartbeat_path,
        start_heartbeat: false,
        # Route the turn's call_llm compute node at our capturing adapter.
        config: %{"llm_provider" => CaptureAdapter.provider(), "llm_model" => "capture-model"}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  # send_message runs the whole turn; a stub-adapter turn may error in a later
  # node (update_memory/checkpoint) — that's irrelevant, we assert on the captured
  # LLM input, which is produced at call_llm (before those nodes). Isolate the call
  # so a turn error can't fail the test.
  defp fire_turn(pid, message) do
    task =
      Task.async(fn ->
        try do
          Session.send_message(pid, message)
        catch
          kind, reason -> {:caught, kind, reason}
        end
      end)

    Task.await(task, 30_000)
  end

  # Drain every {:captured, messages} the turn emitted (call_llm may fire once;
  # a tool loop could fire more). Returns the concatenated inspected payloads.
  defp drain_captured(acc \\ []) do
    receive do
      {:captured, messages} -> drain_captured([inspect(messages) | acc])
    after
      500 -> Enum.join(acc, "\n")
    end
  end

  describe "cross-session memory recall [real turn.dot]" do
    @describetag :integration

    test "a recalled fact reaches a later turn's LLM input", ctx do
      :persistent_term.put({CaptureAdapter, :pid}, self())

      # SESSION 1 (implicit): the fact lands in the agent's persistent memory.
      # Indexing directly is what session_memory.update does at the end of a turn;
      # it survives session restarts (per-agent ETS index), so a fresh session's
      # recall node can retrieve it.
      Arbor.Memory.init_for_agent(@agent_id, index_enabled: true)
      assert {:ok, _entry_id} = Arbor.Memory.index(@agent_id, @fact)

      # SESSION 2: a brand-new session for the same agent asks about the fact.
      pid = start_fresh_session(ctx, @agent_id)
      _ = fire_turn(pid, "what is the deploy passphrase?")

      captured = drain_captured()

      assert captured =~ @fact_marker,
             """
             The planted fact did not reach the LLM input.
             Recall -> build_prompt -> call_llm wiring is broken
             (session.recalled_memories not threaded into the prompt).

             Captured LLM messages:
             #{captured}
             """
    end

    test "control: with no planted fact, nothing reaches the turn's LLM input", ctx do
      :persistent_term.put({CaptureAdapter, :pid}, self())

      # A distinct agent whose memory index is initialized but never populated.
      Arbor.Memory.init_for_agent(@control_agent_id, index_enabled: true)

      pid = start_fresh_session(ctx, @control_agent_id)
      _ = fire_turn(pid, "what is the deploy passphrase?")

      captured = drain_captured()

      refute captured =~ @fact_marker,
             "The fact was never indexed yet appeared in the LLM input:\n#{captured}"
    end
  end
end
