defmodule Arbor.Orchestrator.SessionEngagementCompactorSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Persistence

  @moduletag :security_regression
  @moduletag :fast

  defmodule TestCompactor do
    @behaviour Arbor.Contracts.AI.Compactor

    defstruct full_transcript: [],
              llm_messages: [],
              summary: nil,
              compactions: 0,
              config: %{}

    @impl true
    def new(opts), do: %__MODULE__{config: Map.new(opts)}

    @impl true
    def append(compactor, message) do
      %{
        compactor
        | full_transcript: compactor.full_transcript ++ [message],
          llm_messages: compactor.llm_messages ++ [message]
      }
    end

    @impl true
    def maybe_compact(compactor) do
      count = compactor.compactions + 1
      %{compactor | compactions: count, summary: "engagement-summary-#{count}"}
    end

    @impl true
    def llm_messages(compactor), do: compactor.llm_messages

    @impl true
    def full_transcript(compactor), do: compactor.full_transcript

    @impl true
    def stats(compactor) do
      %{
        total_messages: length(compactor.full_transcript),
        visible_messages: length(compactor.llm_messages),
        compactions_performed: compactor.compactions
      }
    end
  end

  defmodule PromptCaptureAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @parent_key {__MODULE__, :test_parent}

    def set_test_parent(pid), do: :persistent_term.put(@parent_key, pid)
    def clear_test_parent, do: :persistent_term.erase(@parent_key)

    @impl true
    def provider, do: "lm_studio"

    @impl true
    def complete(%Request{} = request, _opts) do
      user_texts =
        request.messages
        |> Enum.filter(&(&1.role == :user))
        |> Enum.map(& &1.content)

      send(
        :persistent_term.get(@parent_key),
        {:provider_prompt, user_texts, request.messages}
      )

      {:ok,
       %Response{
         text: "isolated-response",
         finish_reason: :stop,
         content_parts: [ContentPart.text("isolated-response")],
         usage: %{input_tokens: 1, output_tokens: 1},
         raw: %{}
       }}
    end

    @impl true
    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  setup do
    PromptCaptureAdapter.set_test_parent(self())

    client =
      Client.new(default_provider: PromptCaptureAdapter.provider(), model_catalog: %{})
      |> Client.register_adapter(PromptCaptureAdapter)

    :ok = Client.set_default_client(client)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_engagement_compactor_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    turn_path = Path.join(tmp_dir, "turn.dot")
    File.write!(turn_path, turn_dot())

    on_exit(fn ->
      PromptCaptureAdapter.clear_test_parent()
      Client.clear_default_client()
      File.rm_rf(tmp_dir)
    end)

    %{turn_path: turn_path}
  end

  test "security regression: enabled compactor restores A across A to B to A", ctx do
    pid = start_session!(ctx, compactor: compactor_spec())

    send_engagement!(pid, "eng_a", "alpha-one")
    assert_prompt(["alpha-one"])

    send_engagement!(pid, "eng_b", "beta-one")
    assert_prompt(["beta-one"])

    send_engagement!(pid, "eng_a", "alpha-two")
    assert_prompt(["alpha-one", "alpha-two"])

    state = Session.get_state(pid)

    assert state.current_engagement_id == "eng_a"
    assert state.compactor.summary == "engagement-summary-2"
    assert state.compactor.config == %{marker: :configured}
    assert state.compactors["eng_b"].summary == "engagement-summary-1"
    assert map_size(state.compactors) <= map_size(state.transcripts)

    assert :ok = Session.restore_checkpoint(pid, %{"turn_count" => 99})
    assert Session.get_state(pid).compactor.summary == "engagement-summary-2"
  end

  test "security regression: disabled compactor keeps A to B to A prompts isolated", ctx do
    pid = start_session!(ctx)

    send_engagement!(pid, "eng_a", "disabled-alpha-one")
    assert_prompt(["disabled-alpha-one"])

    send_engagement!(pid, "eng_b", "disabled-beta-one")
    assert_prompt(["disabled-beta-one"])

    send_engagement!(pid, "eng_a", "disabled-alpha-two")
    assert_prompt(["disabled-alpha-one", "disabled-alpha-two"])

    state = Session.get_state(pid)
    assert state.compactor == nil
    assert state.compactors == %{}
  end

  test "security regression: switching from named engagement restores nil default", ctx do
    pid = start_session!(ctx, compactor: compactor_spec())

    assert {:ok, %{content: "isolated-response"}} = Session.send_message(pid, "default-one")
    assert_prompt(["default-one"])

    send_engagement!(pid, "eng_named", "named-one")
    assert_prompt(["named-one"])

    assert {:ok, %{content: "isolated-response"}} = Session.send_message(pid, "default-two")
    assert_prompt(["default-one", "default-two"])

    state = Session.get_state(pid)
    assert state.current_engagement_id == nil
    assert state.compactor.summary == "engagement-summary-2"
    assert state.compactors["eng_named"].summary == "engagement-summary-1"
  end

  test "security regression: restart and engagement switches preserve Session-owned labels",
       ctx do
    agent_id = "agent_checkpoint_switch_#{System.unique_integer([:positive, :monotonic])}"
    session_id = "session-#{agent_id}"
    hostile = taint("checkpoint_hostile", :hostile)
    response_taint = taint("checkpoint_response", :untrusted)

    checkpoint_messages = [
      %{
        "role" => "user",
        "content" => "checkpoint-alpha",
        "taint" => hostile,
        "taint_status" => :verified
      },
      %{
        "role" => "assistant",
        "content" => "checkpoint-response",
        "taint" => response_taint,
        "taint_status" => :verified
      }
    ]

    checkpoint =
      Persistence.extract_checkpoint_data(%Session{
        session_id: session_id,
        agent_id: agent_id,
        messages: checkpoint_messages,
        current_engagement_id: "eng_checkpoint_alpha"
      })

    adapters = %{
      ensure_session: fn ^session_id, ^agent_id, [] -> {:ok, %{id: "checkpoint-uuid"}} end,
      append_session_entries: fn "checkpoint-uuid", entries -> {:ok, length(entries)} end,
      load_recent_session_messages: fn ^session_id, _opts -> [] end
    }

    pid =
      start_session!(ctx,
        agent_id: agent_id,
        session_id: session_id,
        compactor: compactor_spec(),
        checkpoint: checkpoint,
        adapters: adapters
      )

    restored = Session.get_state(pid)

    assert restored.current_engagement_id == "eng_checkpoint_alpha"
    assert [restored_user, restored_assistant] = restored.messages
    assert restored_user["taint"] == hostile
    assert restored_user["taint_status"] == :verified
    assert restored_assistant["taint"] == response_taint
    assert restored_assistant["taint_status"] == :verified

    assert Enum.map(restored.compactor.full_transcript, & &1["content"]) == [
             "checkpoint-alpha",
             "checkpoint-response"
           ]

    assert Persistence.extract_checkpoint_data(restored)["current_engagement_id"] ==
             "eng_checkpoint_alpha"

    send_engagement!(pid, "eng_checkpoint_beta", "beta-after-restart")
    assert_prompt(["beta-after-restart"])

    beta_state = Session.get_state(pid)
    assert [stashed_user | _] = beta_state.transcripts["eng_checkpoint_alpha"]
    assert stashed_user["taint"] == hostile
    assert stashed_user["taint_status"] == :verified

    send_engagement!(pid, "eng_checkpoint_alpha", "alpha-after-restart")
    assert_prompt(["checkpoint-alpha", "alpha-after-restart"])

    alpha_state = Session.get_state(pid)
    assert [alpha_user | _] = alpha_state.messages
    assert alpha_user["taint"] == hostile
    assert alpha_user["taint_status"] == :verified

    assert Enum.all?(alpha_state.transcripts["eng_checkpoint_beta"], fn message ->
             match?(%Taint{}, message["taint"]) and message["taint_status"] == :verified
           end)
  end

  test "security regression: restarted and switched history taints the next Engine run", ctx do
    parent = self()
    agent_id = "agent_history_taint_#{System.unique_integer([:positive, :monotonic])}"
    session_id = "session-#{agent_id}"
    hostile = taint("restored_hostile_history", :hostile)

    checkpoint =
      Persistence.extract_checkpoint_data(%Session{
        session_id: session_id,
        agent_id: agent_id,
        current_engagement_id: "eng-hostile",
        messages: [
          %{
            "role" => "user",
            "content" => "hostile restored history",
            "taint" => hostile,
            "taint_status" => :verified
          }
        ]
      })

    adapters = %{
      ensure_session: fn ^session_id, ^agent_id, [] -> {:ok, %{id: "history-taint-uuid"}} end,
      append_session_entries: fn "history-taint-uuid", entries ->
        send(parent, {:history_taint_batch, entries})
        {:ok, length(entries)}
      end,
      load_recent_session_messages: fn ^session_id, _opts -> [] end
    }

    pid =
      start_session!(ctx,
        agent_id: agent_id,
        session_id: session_id,
        checkpoint: checkpoint,
        adapters: adapters
      )

    send_engagement!(pid, "eng-hostile", "after restart")
    assert_prompt(["hostile restored history", "after restart"])
    assert_hostile_assistant_batch("eng-hostile")

    send_engagement!(pid, "eng-clean", "other engagement")
    assert_prompt(["other engagement"])
    assert_receive {:history_taint_batch, _clean_entries}, 1_000

    send_engagement!(pid, "eng-hostile", "after switch")
    assert_prompt(["hostile restored history", "after restart", "after switch"])
    assert_hostile_assistant_batch("eng-hostile")
  end

  defp start_session!(ctx, opts \\ []) do
    agent_id =
      Keyword.get(
        opts,
        :agent_id,
        "agent_engagement_compactor_#{System.unique_integer([:positive, :monotonic])}"
      )

    session_id = Keyword.get(opts, :session_id, "session-#{agent_id}")
    Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(agent_id)
    on_exit(fn -> Arbor.Orchestrator.TestCapabilities.revoke_all(agent_id) end)

    session_opts =
      [
        session_id: session_id,
        agent_id: agent_id,
        turn_dot: ctx.turn_path,
        config: %{
          # TurnEgress classifies the backend atom `:lmstudio` as on-host;
          # Client canonicalization still routes this spelling to `lm_studio`.
          "llm_provider" => "lmstudio",
          "llm_model" => "deterministic-test-model",
          "stream" => false
        },
        start_heartbeat: false
      ]
      |> Keyword.merge(opts)

    assert {:ok, pid} = Session.start_link(session_opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp send_engagement!(pid, engagement_id, text) do
    message = UserMessage.from_string(text) |> UserMessage.with_engagement(engagement_id)
    assert {:ok, %{content: "isolated-response"}} = Session.send_message(pid, message)
  end

  defp assert_prompt(expected_user_texts) do
    assert_receive {:provider_prompt, user_texts, provider_messages}, 2_000
    assert user_texts == expected_user_texts
    assert Enum.all?(provider_messages, &(&1.metadata == %{}))
  end

  defp assert_hostile_assistant_batch(engagement_id) do
    assert_receive {:history_taint_batch, [_user_entry, assistant_entry]}, 1_000
    assert assistant_entry.metadata["engagement_id"] == engagement_id

    assert {:ok, envelope} =
             Arbor.Contracts.Security.TaintEnvelope.verify(
               assistant_entry.metadata["taint"],
               assistant_entry.content
             )

    assert envelope.taint.level == :hostile
    assert envelope.taint.sensitivity == :restricted
  end

  defp compactor_spec, do: {TestCompactor, marker: :configured}

  defp taint(source, level) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: source,
        chain: []
      })

    taint
  end

  defp turn_dot do
    """
    digraph EngagementCompactorSecurityRegression {
      graph [goal="Engagement compactor isolation"]
      start [shape=Mdiamond]
      call_llm [
        type="compute",
        simulate="false",
        prompt_context_key="session.input",
        messages_context_key="session.messages"
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
  end
end
