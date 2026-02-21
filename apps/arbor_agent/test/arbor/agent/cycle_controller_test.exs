defmodule Arbor.Agent.CycleControllerTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.CycleController
  alias Arbor.Contracts.Memory.{Intent, Percept}

  @agent_id "test_agent_cycle"

  # ── Mock LLM Functions ─────────────────────────────────────────────

  defp llm_wait(_context) do
    {:ok, %{"mental_actions" => [], "intent" => nil, "wait" => true}}
  end

  defp llm_physical_intent(_context) do
    {:ok,
     %{
       "mental_actions" => [],
       "intent" => %{
         "capability" => "fs",
         "op" => "read",
         "target" => "/tmp/test.txt",
         "reason" => "need to read config"
       },
       "wait" => false
     }}
  end

  defp llm_mental_then_physical(context) do
    iteration = Map.get(context, :iteration, 0)

    if iteration == 0 do
      # First iteration: mental action only
      {:ok,
       %{
         "mental_actions" => [
           %{"capability" => "think", "op" => "reflect", "params" => %{"topic" => "planning"}}
         ],
         "intent" => nil,
         "wait" => false
       }}
    else
      # Second iteration: physical intent
      {:ok,
       %{
         "mental_actions" => [],
         "intent" => %{
           "capability" => "shell",
           "op" => "execute",
           "target" => "ls -la",
           "reason" => "list directory"
         },
         "wait" => false
       }}
    end
  end

  defp llm_error(_context) do
    {:error, :api_timeout}
  end

  defp llm_always_mental(_context) do
    {:ok,
     %{
       "mental_actions" => [
         %{"capability" => "think", "op" => "observe", "params" => %{"focus" => "loop"}}
       ],
       "intent" => nil,
       "wait" => false
     }}
  end

  defp llm_no_actions(_context) do
    {:ok,
     %{
       "mental_actions" => [],
       "intent" => nil,
       "wait" => false
     }}
  end

  # ── run/2 ──────────────────────────────────────────────────────────

  describe "run/2" do
    test "returns error without llm_fn" do
      assert {:error, :no_llm_fn} = CycleController.run(@agent_id, [])
    end

    test "handles wait response" do
      result = CycleController.run(@agent_id, llm_fn: &llm_wait/1)

      assert {:wait, percepts} = result
      assert is_list(percepts)
    end

    test "handles physical intent" do
      result = CycleController.run(@agent_id, llm_fn: &llm_physical_intent/1)

      assert {:intent, %Intent{} = intent, percepts} = result
      assert intent.capability == "fs"
      assert intent.op == :read
      assert intent.target == "/tmp/test.txt"
      assert is_list(percepts)
    end

    test "executes mental actions then physical intent" do
      result = CycleController.run(@agent_id, llm_fn: &llm_mental_then_physical/1)

      assert {:intent, %Intent{} = intent, percepts} = result
      assert intent.capability == "shell"
      assert intent.op == :execute

      # Should have at least one percept from the mental action
      assert [_ | _] = percepts
      assert Enum.all?(percepts, &match?(%Percept{}, &1))
    end

    test "handles LLM error" do
      result = CycleController.run(@agent_id, llm_fn: &llm_error/1)

      assert {:error, {:llm_error, :api_timeout}} = result
    end

    test "respects max_iterations safety limit" do
      result =
        CycleController.run(@agent_id,
          llm_fn: &llm_always_mental/1,
          max_iterations: 3
        )

      assert {:wait, percepts} = result
      # Should have executed 3 iterations of mental actions
      assert length(percepts) == 3
    end

    test "exits when Mind returns no actions and no intent" do
      result = CycleController.run(@agent_id, llm_fn: &llm_no_actions/1)

      assert {:wait, []} = result
    end

    test "passes goal context to LLM function" do
      goal = %{id: "g_1", description: "Test goal", progress: 0.5}

      called = :ets.new(:test_called, [:set, :public])
      :ets.insert(called, {:goal_passed, false})

      llm_fn = fn context ->
        if context.goal do
          :ets.insert(called, {:goal_passed, true})
        end

        {:ok, %{"mental_actions" => [], "intent" => nil, "wait" => true}}
      end

      CycleController.run(@agent_id, llm_fn: llm_fn, goal: goal)

      [{:goal_passed, passed}] = :ets.lookup(called, :goal_passed)
      assert passed
      :ets.delete(called)
    end

    test "passes last percept to LLM function" do
      last_percept = Percept.success("intent_1", %{result: "ok"}, summary: "did a thing")

      called = :ets.new(:test_called2, [:set, :public])
      :ets.insert(called, {:percept_passed, false})

      llm_fn = fn context ->
        if context.last_percept do
          :ets.insert(called, {:percept_passed, true})
        end

        {:ok, %{"mental_actions" => [], "intent" => nil, "wait" => true}}
      end

      CycleController.run(@agent_id, llm_fn: llm_fn, last_percept: last_percept)

      [{:percept_passed, passed}] = :ets.lookup(called, :percept_passed)
      assert passed
      :ets.delete(called)
    end

    test "overall cycle timeout" do
      slow_llm = fn _ctx ->
        Process.sleep(5_000)
        {:ok, %{"mental_actions" => [], "intent" => nil, "wait" => true}}
      end

      result = CycleController.run(@agent_id, llm_fn: slow_llm, timeout: 100)

      assert {:error, :cycle_timeout} = result
    end
  end

  # ── extract_mental_actions/1 ───────────────────────────────────────

  describe "extract_mental_actions/1" do
    test "extracts valid mental actions" do
      response = %{
        "mental_actions" => [
          %{"capability" => "memory", "op" => "recall", "params" => %{"query" => "test"}},
          %{"capability" => "goal", "op" => "list", "params" => %{}}
        ]
      }

      actions = CycleController.extract_mental_actions(response)
      assert length(actions) == 2
    end

    test "filters out actions without capability or op" do
      response = %{
        "mental_actions" => [
          %{"capability" => "memory"},
          %{"op" => "recall"},
          %{"capability" => "goal", "op" => "list"}
        ]
      }

      actions = CycleController.extract_mental_actions(response)
      assert length(actions) == 1
    end

    test "handles missing mental_actions key" do
      assert [] = CycleController.extract_mental_actions(%{})
    end

    test "handles non-map response" do
      assert [] = CycleController.extract_mental_actions("invalid")
    end

    test "supports atom keys" do
      response = %{
        mental_actions: [
          %{capability: "think", op: "reflect", params: %{topic: "test"}}
        ]
      }

      actions = CycleController.extract_mental_actions(response)
      assert length(actions) == 1
    end
  end

  # ── extract_intent/1 ──────────────────────────────────────────────

  describe "extract_intent/1" do
    test "extracts physical intent" do
      response = %{
        "intent" => %{
          "capability" => "fs",
          "op" => "read",
          "target" => "/tmp/file",
          "reason" => "testing"
        }
      }

      assert {:ok, %Intent{} = intent} = CycleController.extract_intent(response)
      assert intent.capability == "fs"
      assert intent.op == :read
      assert intent.target == "/tmp/file"
    end

    test "returns :wait when wait is true" do
      response = %{"wait" => true}
      assert :wait = CycleController.extract_intent(response)
    end

    test "returns :continue when no intent and not waiting" do
      response = %{"intent" => nil, "wait" => false}
      assert :continue = CycleController.extract_intent(response)
    end

    test "returns :continue for mental capability in intent" do
      response = %{
        "intent" => %{
          "capability" => "goal",
          "op" => "list",
          "target" => nil
        }
      }

      # goal.list is mental, not physical — should continue
      assert :continue = CycleController.extract_intent(response)
    end

    test "returns :continue for unknown capability" do
      response = %{
        "intent" => %{
          "capability" => "nonexistent",
          "op" => "nope"
        }
      }

      assert :continue = CycleController.extract_intent(response)
    end

    test "handles non-map response" do
      assert :continue = CycleController.extract_intent("invalid")
    end

    test "supports atom keys" do
      response = %{
        intent: %{
          capability: "shell",
          op: "execute",
          target: "echo hello",
          reason: "testing"
        }
      }

      assert {:ok, %Intent{}} = CycleController.extract_intent(response)
    end
  end

  # ── build_context/4 ────────────────────────────────────────────────

  describe "build_context/4" do
    test "includes required fields" do
      context = CycleController.build_context(@agent_id, [], [], 0)

      assert context.agent_id == @agent_id
      assert context.iteration == 0
      assert is_binary(context.capabilities)
      assert is_binary(context.mental_capabilities)
      assert is_binary(context.response_format)
    end

    test "includes goal when provided" do
      goal = %{id: "g_1", description: "Test", progress: 0.5}
      context = CycleController.build_context(@agent_id, [goal: goal], [], 0)

      assert context.goal.id == "g_1"
      assert context.goal.description == "Test"
      assert context.goal.progress == 0.5
    end

    test "includes last percept when provided" do
      percept = Percept.success("i_1", %{}, summary: "did thing")
      context = CycleController.build_context(@agent_id, [last_percept: percept], [], 0)

      assert context.last_percept.outcome == :success
      assert context.last_percept.summary == "did thing"
    end

    test "includes recent percepts from cycle" do
      percepts = [
        Percept.success("i_1", %{}, summary: "first"),
        Percept.success("i_2", %{}, summary: "second")
      ]

      context = CycleController.build_context(@agent_id, [], percepts, 2)

      assert length(context.recent_percepts) == 2
      assert context.iteration == 2
    end

    test "merges extra context" do
      context =
        CycleController.build_context(
          @agent_id,
          [context: %{custom_key: "custom_value"}],
          [],
          0
        )

      assert context.custom_key == "custom_value"
    end
  end
end
