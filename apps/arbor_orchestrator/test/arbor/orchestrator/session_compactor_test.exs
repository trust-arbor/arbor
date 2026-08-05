defmodule Arbor.Orchestrator.SessionCompactorTest do
  @moduledoc """
  Tests for compactor integration in Session and Builders.

  Verifies that:
  1. Compactors are initialized from {module, opts} config
  2. Messages are appended to the compactor on turn result
  3. The projected view is used for LLM calls
  4. Full transcript is preserved regardless of compaction
  5. Sessions without a compactor behave unchanged
  """
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Orchestrator.Session.Builders

  # ── Mock Compactor ────────────────────────────────────────────

  defmodule TestCompactor do
    @behaviour Arbor.Contracts.AI.Compactor

    defstruct messages: [], transcript: [], compact_count: 0, window: 10

    @impl true
    def new(opts) do
      %__MODULE__{window: Keyword.get(opts, :effective_window, 10)}
    end

    @impl true
    def append(%__MODULE__{} = c, message) do
      %{c | messages: c.messages ++ [message], transcript: c.transcript ++ [message]}
    end

    @impl true
    def maybe_compact(%__MODULE__{} = c) do
      if length(c.messages) > c.window do
        # Keep only most recent half
        keep = div(c.window, 2)
        %{c | messages: Enum.take(c.messages, -keep), compact_count: c.compact_count + 1}
      else
        c
      end
    end

    @impl true
    def llm_messages(%__MODULE__{messages: msgs}), do: msgs

    @impl true
    def full_transcript(%__MODULE__{transcript: t}), do: t

    @impl true
    def stats(%__MODULE__{} = c) do
      %{
        total_messages: length(c.transcript),
        visible_messages: length(c.messages),
        compression_ratio:
          if(c.transcript != [],
            do: length(c.messages) / length(c.transcript),
            else: 1.0
          ),
        compactions_performed: c.compact_count
      }
    end
  end

  defmodule SummaryCompactor do
    @behaviour Arbor.Contracts.AI.Compactor

    defstruct transcript: [], summary: []

    @impl true
    def new(opts) do
      %__MODULE__{summary: Keyword.fetch!(opts, :summary)}
    end

    @impl true
    def append(%__MODULE__{} = compactor, message) do
      %{compactor | transcript: compactor.transcript ++ [message]}
    end

    @impl true
    def maybe_compact(%__MODULE__{} = compactor), do: compactor

    @impl true
    def llm_messages(%__MODULE__{summary: summary}), do: summary

    @impl true
    def full_transcript(%__MODULE__{transcript: transcript}), do: transcript

    @impl true
    def stats(%__MODULE__{} = compactor) do
      %{
        total_messages: length(compactor.transcript),
        visible_messages: length(compactor.summary),
        compression_ratio: 1.0,
        compactions_performed: 1
      }
    end
  end

  # ── init_compactor/1 ──────────────────────────────────────────

  describe "init_compactor/1" do
    test "returns nil for nil config" do
      assert Builders.init_compactor(nil) == nil
    end

    test "returns nil for invalid config" do
      assert Builders.init_compactor(:bad) == nil
    end

    test "creates compactor from {module, opts} tuple" do
      compactor = Builders.init_compactor({TestCompactor, [effective_window: 20]})

      assert %TestCompactor{} = compactor
      assert compactor.window == 20
    end

    test "returns nil when module is not loaded" do
      compactor = Builders.init_compactor({NonExistentCompactorModule, []})

      assert compactor == nil
    end
  end

  # ── Compactor in build_turn_values ────────────────────────────

  describe "build_turn_values with compactor" do
    test "uses compactor projected view for session.messages" do
      compactor = TestCompactor.new(effective_window: 100)

      # Seed the compactor with some messages
      compactor = TestCompactor.append(compactor, %{"role" => "user", "content" => "old message"})

      compactor =
        TestCompactor.append(compactor, %{"role" => "assistant", "content" => "old reply"})

      state = build_state(compactor: compactor)
      values = Builders.build_turn_values(state, "new message")

      messages = values["session.messages"]
      # Should have: old message + old reply (from compactor) + new user msg
      assert length(messages) == 3
      assert List.last(messages)["content"] == "new message"
    end

    test "without compactor uses state.messages" do
      state =
        build_state(
          compactor: nil,
          messages: [%{"role" => "user", "content" => "existing"}]
        )

      values = Builders.build_turn_values(state, "hello")

      messages = values["session.messages"]
      # existing + new user msg
      assert length(messages) == 2
    end
  end

  # ── Compactor in apply_turn_result ────────────────────────────

  describe "apply_turn_result with compactor" do
    test "appends user and assistant messages to compactor" do
      compactor = TestCompactor.new(effective_window: 100)
      state = build_state(compactor: compactor)

      result = %{context: %{"session.response" => "Hello back!"}}
      new_state = Builders.apply_turn_result(state, "Hi there", result)

      assert %TestCompactor{} = new_state.compactor
      assert length(TestCompactor.full_transcript(new_state.compactor)) == 2
      assert length(TestCompactor.llm_messages(new_state.compactor)) == 2

      [user_msg, assistant_msg] = TestCompactor.full_transcript(new_state.compactor)
      assert user_msg["content"] == "Hi there"
      assert assistant_msg["content"] == "Hello back!"
    end

    test "runs compaction after appending" do
      # Window of 2 means compaction triggers after 3+ messages
      compactor = TestCompactor.new(effective_window: 2)

      # Pre-seed with messages so next append triggers compaction
      compactor = TestCompactor.append(compactor, %{"role" => "system", "content" => "system"})
      compactor = TestCompactor.append(compactor, %{"role" => "user", "content" => "first"})

      state = build_state(compactor: compactor)
      result = %{context: %{"session.response" => "reply"}}
      new_state = Builders.apply_turn_result(state, "second", result)

      # Full transcript has all 4 (system + first + second + reply)
      assert length(TestCompactor.full_transcript(new_state.compactor)) == 4
      # LLM messages should be compacted (window=2, so keeps 1)
      assert length(TestCompactor.llm_messages(new_state.compactor)) < 4
      assert new_state.compactor.compact_count > 0
    end

    test "without compactor state.messages still updated" do
      state = build_state(compactor: nil)
      result = %{context: %{"session.response" => "reply"}}
      new_state = Builders.apply_turn_result(state, "hello", result)

      assert new_state.compactor == nil
      assert length(new_state.messages) == 2
    end

    test "full transcript preserved through multiple turns" do
      compactor = TestCompactor.new(effective_window: 3)
      state = build_state(compactor: compactor)

      # Simulate multiple turns
      state =
        Enum.reduce(1..5, state, fn i, acc ->
          result = %{context: %{"session.response" => "reply #{i}"}}
          Builders.apply_turn_result(acc, "msg #{i}", result)
        end)

      transcript = TestCompactor.full_transcript(state.compactor)
      # 5 turns * 2 messages = 10 total
      assert length(transcript) == 10

      # LLM messages should be fewer due to compaction
      visible = TestCompactor.llm_messages(state.compactor)
      assert length(visible) < 10
    end

    @tag :security_regression
    test "security regression: synthetic compactor projection never replaces live labeled history" do
      prior_user = labeled_message("user", "original question", "prior_user")
      prior_assistant = labeled_message("assistant", "original answer", "prior_assistant")

      summary = [
        %{"role" => "system", "content" => "synthetic provider-only summary"}
      ]

      compactor = SummaryCompactor.new(summary: summary)

      state =
        build_state(
          messages: [prior_user, prior_assistant],
          compactor: compactor,
          adapters: persistence_adapters()
        )

      assert Builders.build_turn_values(state, "follow-up")["session.messages"] ==
               summary ++ [%{"role" => "user", "content" => "follow-up"}]

      input_taint = taint("current_user")
      output_taint = taint("current_assistant")

      result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "follow-up",
          "session.response" => "new answer"
        },
        taint: %{
          "session.input" => input_taint,
          "session.response" => output_taint
        }
      }

      updated = Builders.apply_turn_result(state, "follow-up", result)

      assert [^prior_user, ^prior_assistant, live_user, live_assistant] = updated.messages
      refute Enum.any?(updated.messages, &(&1["content"] == "synthetic provider-only summary"))
      assert live_user["content"] == "follow-up"
      assert live_user["taint"] == input_taint
      assert live_user["taint_status"] == :verified
      assert live_assistant["content"] == "new answer"
      assert live_assistant["taint_status"] == :verified
      assert live_assistant["taint"].level == :untrusted
    end
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp build_state(overrides) do
    defaults = %{
      session_id: "test-session",
      agent_id: "test-agent",
      trust_tier: :established,
      turn_count: 0,
      messages: [],
      working_memory: %{},
      goals: [],
      cognitive_mode: :reflection,
      phase: :idle,
      session_type: :primary,
      config: %{},
      signal_topic: "test",
      trace_id: nil,
      compactor: nil,
      session_state: nil,
      session_config: nil,
      behavior: nil,
      adapters: %{}
    }

    struct(Arbor.Orchestrator.Session, Map.new(Enum.into(overrides, defaults)))
  end

  defp labeled_message(role, content, source) do
    %{
      "role" => role,
      "content" => content,
      "taint" => taint(source),
      "taint_status" => :verified
    }
  end

  defp taint(source) do
    {:ok, taint} =
      Taint.new(%{
        level: :untrusted,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: source,
        chain: []
      })

    taint
  end

  defp persistence_adapters do
    %{
      ensure_session: fn _session_id, _agent_id, [] -> {:ok, %{id: "session-uuid"}} end,
      append_session_entries: fn _session_uuid, entries -> {:ok, length(entries)} end
    }
  end
end
