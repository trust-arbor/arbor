defmodule Arbor.Agent.PromptMemorySensitivitySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{APIAgent, HeartbeatLLM}
  alias Arbor.Contracts.Memory.Goal
  alias Arbor.LLM.{Client, Plugs.Dispatch}
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter

  @moduletag :fast
  @moduletag :integration
  @model "prompt-memory-fixture-model"

  # Only the HTTP transport is replaced. Memory, prompt assembly, AI, LLM
  # admission, ReqLLM serialization and the final dispatch gate are real.
  defmodule FixtureHTTP do
    def call(%Arbor.LLM.Call{request: {model, messages, opts}} = call) do
      opts =
        Keyword.merge(opts,
          api_key: "fixture",
          req_http_options: [
            plug: {Req.Test, Arbor.Agent.PromptMemorySensitivitySecurityRegressionTest},
            retry: false,
            redirect: false
          ]
        )

      %{call | request: {model, messages, opts}}
    end
  end

  setup do
    previous_client = :persistent_term.get({Client, :default_client}, nil)
    bridge_key = {Arbor.AI.UnifiedBridge, :client}
    previous_bridge = :persistent_term.get(bridge_key, :missing)
    keys = [:pipeline, :sensitivity_policy]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_llm, &1)})
    Application.delete_env(:arbor_llm, :sensitivity_policy)
    Application.put_env(:arbor_llm, :pipeline, [FixtureHTTP, Dispatch])
    client = Client.new(adapters: %{"openai" => Adapter})
    Client.set_default_client(client)
    :persistent_term.put(bridge_key, client)
    Arbor.Common.Config.Testing.isolate_namespace()
    Arbor.Common.Config.Testing.put(:project_context_enabled, false)
    Arbor.Common.Config.Testing.put(:skill_catalog_enabled, false)
    Arbor.Common.Config.Testing.put(:tool_catalog_enabled, false)

    Req.Test.set_req_test_to_shared()
    observer = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      send(observer, {:prompt_memory_dispatch, Jason.decode!(bytes)})

      Req.Test.json(conn, %{
        "id" => "prompt-memory-fixture",
        "object" => "chat.completion",
        "created" => 0,
        "model" => @model,
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{
                "type" => "output_text",
                "text" => "{\"thinking\":\"Fixture reply\",\"actions\":[]}"
              }
            ]
          }
        ],
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => "{\"thinking\":\"Fixture reply\",\"actions\":[]}"
            }
          }
        ],
        "usage" => %{
          "input_tokens" => 2,
          "output_tokens" => 2,
          "prompt_tokens" => 2,
          "completion_tokens" => 2,
          "total_tokens" => 4
        }
      })
    end)

    on_exit(fn ->
      if previous_bridge == :missing,
        do: :persistent_term.erase(bridge_key),
        else: :persistent_term.put(bridge_key, previous_bridge)

      if previous_client,
        do: Client.set_default_client(previous_client),
        else: Client.clear_default_client()

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    {:ok, agent_id: "agent_prompt_memory_#{System.unique_integer([:positive])}"}
  end

  test "public heartbeat instructions still reach the real cloud adapter", %{agent_id: agent_id} do
    state = heartbeat_state(agent_id, [:response_format])

    result = HeartbeatLLM.think(state, provider: :openai, model: @model)
    assert_receive {:prompt_memory_dispatch, _}
    assert {:ok, %{thinking: "Fixture reply"}} = result
  end

  test "security regression: newly fetched private goals cannot lose their floor in heartbeat prose",
       %{agent_id: agent_id} do
    add_private_goal(agent_id)
    state = heartbeat_state(agent_id, [:goals, :response_format])

    assert {:error, {:sensitivity_blocked, _}} =
             HeartbeatLLM.think(state,
               provider: :openai,
               model: @model,
               sensitivity: :public
             )

    refute_receive {:prompt_memory_dispatch, _}
  end

  test "security regression: direct API queries preserve private memory fetched after host startup",
       %{agent_id: agent_id} do
    host =
      start_supervised!(
        {APIAgent,
         id: agent_id,
         provider: :openai,
         model: @model,
         memory_enabled: false,
         skip_executor: true}
      )

    # The host's state was initialized before the goal existed. Only the prompt
    # builder's fresh Memory read can supply this recorded source floor.
    add_private_goal(agent_id)

    result =
      APIAgent.query(host, "Ordinary synthetic request",
        recall_memories: false,
        index_response: false,
        sensitivity: :public
      )

    refute_receive {:prompt_memory_dispatch, _}
    assert {:error, {:sensitivity_blocked, _}} = result
  end

  test "public API query without private memory reaches the real cloud adapter", %{
    agent_id: agent_id
  } do
    host =
      start_supervised!(
        {APIAgent,
         id: agent_id,
         provider: :openai,
         model: @model,
         memory_enabled: false,
         skip_executor: true}
      )

    result =
      APIAgent.query(host, "Ordinary synthetic request",
        recall_memories: false,
        index_response: false
      )

    assert_receive {:prompt_memory_dispatch, _}
    assert {:ok, %{text: text}} = result
    assert text =~ "Fixture reply"
  end

  defp heartbeat_state(agent_id, sections) do
    %{
      id: agent_id,
      agent_id: agent_id,
      cognitive_mode: :consolidation,
      enabled_prompt_sections: sections,
      pending_messages: [],
      background_suggestions: [],
      context_window: nil
    }
  end

  defp add_private_goal(agent_id) do
    goal = Goal.new("Review the ordinary synthetic launch plan")
    assert {:ok, _} = Arbor.Memory.add_goal(agent_id, goal)
    assert Enum.any?(Arbor.Memory.get_active_goals(agent_id), &(&1.id == goal.id))
    on_exit(fn -> Arbor.Memory.abandon_goal(agent_id, goal.id, "fixture complete") end)
  end
end
