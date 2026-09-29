defmodule Arbor.Orchestrator.Pipelines.HeartbeatFollowupRequestRegressionTest do
  @moduledoc """
  Regression: every heartbeat variant's tool-loop followup must reach the
  provider as the same agent, continuing the same conversation.

  Before 2026-09-27 `llm_followup` declared no `system_prompt_context_key`, so
  `LlmHandler.build_llm_messages/5` fell back to "You are a coding agent
  working on the following goal: <graph goal>", and `build_followup` passed
  only the action results (heartbeat `session.messages` starts every beat as
  `[]`). Each followup reply was produced with neither the agent's identity,
  the heartbeat prompt it was following up on, nor its own prior reply.

  Runs the real `build_followup` and `llm_followup` nodes from each variant
  through the engine (ExecHandler context-key binding into the real
  `session_llm.build_prompt` action, then LlmHandler), twice in sequence so the
  engine carries `session.messages` and `last_response` between iterations the
  way the tool loop does. Only the LLM dispatcher is stubbed.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.{Message, Response}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  @variants ~w(heartbeat.dot heartbeat-full.dot heartbeat-bare.dot heartbeat-goals.dot
               heartbeat-notes.dot heartbeat-identity.dot)

  @agent_system_prompt "You are Sentinel-7, a persistent Arbor agent. IDENTITY-MARKER-4b1e."
  @generic_fallback "You are a coding agent"
  @heartbeat_prompt "HEARTBEAT-PROMPT-7c2d: pursue goal G-1 (read lib/foo.ex)"
  @llm_call_reply ~s({"actions": [{"type": "file.read", "params": {"path": "lib/foo.ex"}}]})

  defmodule CapturingDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    @impl true
    def dispatch(request, _opts) do
      test_pid = Application.fetch_env!(:arbor_orchestrator, :heartbeat_followup_test_pid)
      send(test_pid, {:llm_request, request})

      {:ok,
       %Response{
         text: "followup-reply-after-#{length(request.messages)}-messages",
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end
  end

  setup do
    prior_dispatcher = Application.get_env(:arbor_orchestrator, :llm_dispatcher)
    prior_profile = Application.get_env(:arbor_ai, :provider_route_profile)

    Application.put_env(:arbor_orchestrator, :llm_dispatcher, CapturingDispatcher)
    Application.put_env(:arbor_orchestrator, :heartbeat_followup_test_pid, self())
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})

    logs_root =
      Path.join(System.tmp_dir!(), "hb-followup-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env(:arbor_orchestrator, :llm_dispatcher, prior_dispatcher)
      Application.delete_env(:arbor_orchestrator, :heartbeat_followup_test_pid)
      restore_env(:arbor_ai, :provider_route_profile, prior_profile)
      File.rm_rf(logs_root)
    end)

    %{logs_root: logs_root}
  end

  test "every heartbeat variant is covered" do
    on_disk =
      pipelines_dir()
      |> Path.join("heartbeat*.dot")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert on_disk == Enum.sort(@variants),
           "heartbeat variants on disk changed; add new ones to @variants so their " <>
             "tool-loop followup stays covered"
  end

  # Capability-free backstop for the wiring the engine test below exercises.
  test "every variant wires the followup conversation inputs and the system prompt" do
    for variant <- @variants do
      {:ok, graph} = variant |> dot_path() |> File.read!() |> Arbor.Orchestrator.parse()
      build_keys = String.split(graph.nodes["build_followup"].attrs["context_keys"], ",")

      for key <- ~w(session.percepts session.messages session.heartbeat_prompt last_response) do
        assert key in build_keys, "#{variant} build_followup does not bind #{key}"
      end

      assert graph.nodes["llm_followup"].attrs["system_prompt_context_key"] ==
               graph.nodes["llm_call"].attrs["system_prompt_context_key"],
             "#{variant} llm_followup and llm_call use different system prompts"
    end
  end

  for variant <- @variants do
    @variant variant

    test "#{variant}: followups carry the agent system prompt and the beat's conversation",
         ctx do
      agent_id = "agent_hb_followup_#{System.unique_integer([:positive])}"

      # build_followup's action is capability-gated. Assert the grant so a
      # refused grant fails here with its reason, not later as "unauthorized".
      assert {:ok, capability} =
               Arbor.Security.grant(
                 principal: agent_id,
                 resource: "arbor://orchestrator/execute/**"
               )

      on_exit(fn -> Arbor.Security.revoke(capability.id) end)

      assert {:ok, result} =
               Arbor.Orchestrator.run(two_iteration_loop(@variant),
                 agent_id: agent_id,
                 execution_principal: agent_id,
                 authorization: false,
                 resumable: false,
                 logs_root: ctx.logs_root,
                 initial_values: %{
                   "session.agent_id" => agent_id,
                   "session.llm_provider" => "stub-provider",
                   "session.llm_model" => "stub-model",
                   "session.llm_runtime" => :arbor,
                   "session.system_prompt" => @agent_system_prompt,
                   # What build_prompt and llm_call leave behind on the first pass.
                   "session.heartbeat_prompt" => @heartbeat_prompt,
                   "last_response" => @llm_call_reply,
                   "session.messages" => [],
                   "session.percepts" => [
                     %{
                       "outcome" => "success",
                       "data" => %{"action_type" => "file.read", "result" => "defmodule Foo"}
                     }
                   ]
                 }
               )

      assert result.final_outcome.status == :success, inspect(result.final_outcome)

      assert_receive {:llm_request, first}
      assert_receive {:llm_request, second}

      for request <- [first, second] do
        assert [%Message{role: :system, content: system} | _] = request.messages
        assert Enum.count(request.messages, &(&1.role == :system)) == 1

        assert system =~ @agent_system_prompt,
               "#{@variant} followup system message lacks the agent system prompt:\n#{system}"

        refute system =~ @generic_fallback,
               "#{@variant} followup fell back to the generic coding-agent prompt"
      end

      assert [
               {:user, @heartbeat_prompt},
               {:assistant, @llm_call_reply},
               {:user, results}
             ] = turns(first)

      assert results =~ "Action Results"
      assert results =~ "defmodule Foo"

      # The second followup continues the same conversation: the heartbeat
      # prompt once, then each reply before the results that answered it.
      assert [
               {:user, @heartbeat_prompt},
               {:assistant, @llm_call_reply},
               {:user, ^results},
               {:assistant, "followup-reply-after-4-messages"},
               {:user, ^results}
             ] = turns(second)
    end
  end

  # start -> build_followup -> llm_followup -> build_followup_2 -> llm_followup_2 -> done,
  # using the variant's own node attrs for both iterations.
  defp two_iteration_loop(filename) do
    {:ok, parsed} = filename |> dot_path() |> File.read!() |> Arbor.Orchestrator.parse()

    build = Map.fetch!(parsed.nodes, "build_followup")
    call = Map.fetch!(parsed.nodes, "llm_followup")

    nodes = [
      Map.fetch!(parsed.nodes, "start"),
      build,
      call,
      %Node{id: "build_followup_2", attrs: build.attrs},
      %Node{id: "llm_followup_2", attrs: call.attrs},
      Map.fetch!(parsed.nodes, "done")
    ]

    graph =
      Enum.reduce(nodes, %Graph{id: parsed.id, attrs: parsed.attrs}, &Graph.add_node(&2, &1))

    nodes
    |> Enum.map(& &1.id)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [from, to], acc -> Graph.add_edge(acc, %Edge{from: from, to: to}) end)
  end

  defp turns(request) do
    request.messages
    |> Enum.reject(&(&1.role == :system))
    |> Enum.map(&{&1.role, &1.content})
  end

  defp dot_path(filename), do: Path.join(pipelines_dir(), filename)

  defp pipelines_dir do
    [
      Path.join([File.cwd!(), "specs", "pipelines", "session"]),
      Path.join([File.cwd!(), "apps", "arbor_orchestrator", "specs", "pipelines", "session"])
    ]
    |> Enum.find(&File.dir?/1)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
