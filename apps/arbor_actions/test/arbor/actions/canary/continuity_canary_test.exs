defmodule Arbor.Actions.Canary.ContinuityCanaryTest do
  @moduledoc """
  **C1 — Continuity canary.** The north-star regression guard from
  `.arbor/roadmap/2-planned/north-star-and-regression-canaries.md`.

  ## What it probes

  A scripted three-session arc: plant a durable preference in S1, run an
  unrelated S2, then in S3 ask something that needs the S1 fact. It asserts the
  fact travels the WHOLE chain and lands in the message list handed to the
  provider:

      index (S1) -> recall (S3, session_memory.recall)
                 -> session.recalled_memories
                 -> build_prompt mode="turn"
                 -> leading system message

  ## Why it asserts on the prompt, not on the memory store

  This canary exists because of the canonical proxy-drift case (2026-07-04):
  compaction retention scored 97% while recall never reached the turn prompt.
  A perfect component score with zero delivered value. Every assertion below is
  therefore on what the LLM would actually receive — the last link, which is
  the one that broke and the one no component test covered.

  The turn-mode injection in `SessionLlm.BuildPrompt.build_turn/1` was itself
  lost in the DOT migration and re-established on 2026-07-04. Nothing guarded
  it. This is that guard.

  ## What this does NOT prove

  The hermetic lane uses hash-based test embeddings
  (`config/test.exs: embedding_test_fallback`), so semantic RANKING is not
  meaningful here — a query does not semantically match its fact. This canary
  proves the **plumbing**: that whatever recall returns reaches the prompt
  intact. Retrieval quality is a drift trendline, not a regression gate, and
  belongs in the `:llm` lane against real embeddings.

  It also does not prove the model USED the fact. That needs a real completion
  and lives in the non-gating `:llm` lane.
  """

  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.SessionLlm.BuildPrompt
  alias Arbor.Actions.SessionMemory.Recall
  alias Arbor.Memory

  @moduletag :fast
  @moduletag :canary

  # A preference, not a fact about the world: the thing a user would be annoyed
  # to have to repeat. That is the experience C1 is defending.
  @planted_fact "Hysun deploys Arbor with Postgres, never SQLite, because the telemetry queries need it"
  @s3_question "Which database should I use for this deployment?"

  # test_helper.exs starts the memory stores and the durable graph authority for
  # the whole suite. This block is a self-contained fallback so the canary keeps
  # working if that boot profile changes — it needs only the index -> recall
  # path, which is a much smaller set. Already-started children are a no-op.
  setup_all do
    for table <- [:arbor_memory_graphs, :arbor_working_memory] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    for child <- [
          {Registry, keys: :unique, name: Arbor.Memory.Registry},
          {Arbor.Memory.Provenance, []},
          {Arbor.Memory.IndexSupervisor, []}
        ] do
      case Supervisor.start_child(Arbor.Memory.Supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    :ok
  end

  setup do
    agent_id = "canary_continuity_#{System.unique_integer([:positive])}"

    # graph_enabled: false — this canary probes the index -> recall -> prompt
    # chain. The knowledge graph needs a durable authority whose test double
    # lives in arbor_memory's test support and is not reachable from here.
    {:ok, _pid} = Memory.init_for_agent(agent_id, graph_enabled: false)
    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)
    {:ok, agent_id: agent_id}
  end

  defp session_1_plant(agent_id) do
    {:ok, _} = Memory.index(agent_id, @planted_fact, %{type: :preference})
    :ok
  end

  defp session_2_unrelated(agent_id) do
    for content <- [
          "The BEAM schedulers are per-core",
          "Kerrville is in the Texas Hill Country",
          "DOT pipelines are validated before they run"
        ] do
      {:ok, _} = Memory.index(agent_id, content, %{type: :fact})
    end

    :ok
  end

  # S3 runs the REAL actions the turn pipeline runs — not a hand-built map.
  # If either action's contract drifts, this canary goes red, which is the point.
  defp session_3_recall_and_build(agent_id, question) do
    {:ok, recall_out} = Recall.run(%{agent_id: agent_id, query: question}, %{})

    {:ok, prompt_out} =
      BuildPrompt.run(
        %{
          mode: "turn",
          messages: [%{"role" => "user", "content" => question}],
          recalled_memories: recall_out[:recalled_memories] || []
        },
        %{}
      )

    {recall_out, prompt_out}
  end

  defp rendered(messages), do: messages |> Enum.map_join("\n", &(&1["content"] || ""))

  describe "C1 — a fact planted in session 1 reaches the session 3 prompt" do
    test "the planted preference is in the messages handed to the provider",
         %{agent_id: agent_id} do
      :ok = session_1_plant(agent_id)
      :ok = session_2_unrelated(agent_id)

      {recall_out, prompt_out} = session_3_recall_and_build(agent_id, @s3_question)

      recalled = recall_out[:recalled_memories] || []

      assert recalled != [],
             "recall returned nothing — the chain is broken at retrieval, before the prompt"

      # THE assertion. Everything upstream can be perfect and this can still
      # fail; that is exactly what happened in the P0a bug.
      assert rendered(prompt_out[:messages]) =~ "Postgres",
             "the planted fact never reached the prompt — recall ran, but its output " <>
               "did not survive into the messages the model sees. This is the P0a " <>
               "regression class: a perfect component score with zero delivered value."
    end

    test "recall rides the user turn, ahead of the question and outside the cached prefix",
         %{agent_id: agent_id} do
      :ok = session_1_plant(agent_id)

      {_recall_out, prompt_out} = session_3_recall_and_build(agent_id, @s3_question)

      # Recall used to be prepended as a leading SYSTEM message. It is
      # query-relevant and so changes every turn, which put volatile content
      # inside the one part of the request that must stay byte-identical for the
      # provider's prefix cache — and a second system message is rejected
      # outright by OpenAI-compatible providers. It now attaches to the user
      # turn, matching the stable/volatile split APIAgent already used.
      refute Enum.any?(prompt_out[:messages], &(&1["role"] == "system")),
             "recall must not introduce a system message: #{inspect(prompt_out[:messages])}"

      assert [%{"role" => "user", "content" => content}] = prompt_out[:messages]

      # Placement within the turn still matters: context first, question last,
      # so the model reads the memory before the thing it has to answer.
      assert content =~ "Postgres"
      assert content =~ @s3_question

      assert :binary.match(content, "Postgres") < :binary.match(content, @s3_question),
             "the recalled context must precede the user's question"
    end

    test "the user's question survives the injection", %{agent_id: agent_id} do
      :ok = session_1_plant(agent_id)

      {_recall_out, prompt_out} = session_3_recall_and_build(agent_id, @s3_question)

      assert prompt_out[:user_prompt] == @s3_question
      assert rendered(prompt_out[:messages]) =~ @s3_question
    end
  end

  describe "C1 — negative controls" do
    # Without these, the canary could pass by asserting on a string that is
    # always present for some unrelated reason.
    test "an agent with no planted memory gets no injected system message",
         %{agent_id: agent_id} do
      {_recall_out, prompt_out} = session_3_recall_and_build(agent_id, @s3_question)

      refute rendered(prompt_out[:messages]) =~ "Postgres",
             "nothing was planted, so nothing should surface"

      assert Enum.all?(prompt_out[:messages], &(&1["role"] != "system")),
             "empty recall must not add a stray system message"
    end

    test "the injection carries recall content, not a fixed template",
         %{agent_id: agent_id} do
      distinctive = "The canary sentinel value is xyzzy_#{System.unique_integer([:positive])}"
      {:ok, _} = Memory.index(agent_id, distinctive, %{type: :fact})

      {_recall_out, prompt_out} = session_3_recall_and_build(agent_id, "sentinel")

      assert rendered(prompt_out[:messages]) =~ "xyzzy",
             "the injected section must contain the recalled text itself"
    end
  end
end
