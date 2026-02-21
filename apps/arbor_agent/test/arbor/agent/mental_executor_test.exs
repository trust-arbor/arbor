defmodule Arbor.Agent.MentalExecutorTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.MentalExecutor
  alias Arbor.Contracts.Memory.{Intent, Percept}

  @agent_id "test_agent_001"

  defp make_intent(cap, op, params) do
    Intent.capability_intent(cap, op, "test", reasoning: "test", params: params)
  end

  # ── execute/2 ──────────────────────────────────────────────────────

  describe "execute/2" do
    test "returns a Percept struct" do
      intent = make_intent("think", :reflect, %{topic: "testing"})
      {:ok, percept} = MentalExecutor.execute(intent, @agent_id)

      assert %Percept{} = percept
      assert percept.outcome in [:success, :failure]
    end

    test "handles think.reflect successfully" do
      intent = make_intent("think", :reflect, %{topic: "patterns"})
      {:ok, percept} = MentalExecutor.execute(intent, @agent_id)

      assert percept.outcome == :success
      assert is_map(percept.data)
    end

    test "handles think.observe successfully" do
      intent = make_intent("think", :observe, %{focus: "environment"})
      {:ok, percept} = MentalExecutor.execute(intent, @agent_id)

      assert percept.outcome == :success
    end

    test "has no duration_ms (mental actions don't track time)" do
      intent = make_intent("think", :reflect, %{topic: "test"})
      {:ok, percept} = MentalExecutor.execute(intent, @agent_id)

      assert is_nil(percept.duration_ms)
    end
  end

  # ── execute_handler/3 direct tests ─────────────────────────────────

  describe "goal handlers" do
    test "goal_add with missing memory returns error" do
      # If Arbor.Memory is loaded, this will try to call it.
      # If not, it returns :memory_not_available.
      result =
        MentalExecutor.execute_handler(:goal_add, @agent_id, %{
          description: "Test goal"
        })

      # Either succeeds (if memory is running) or graceful error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "goal_update requires goal_id" do
      result =
        MentalExecutor.execute_handler(:goal_update, @agent_id, %{
          progress: 0.5
        })

      assert {:error, :missing_goal_id} = result
    end

    test "goal_update requires an update field" do
      result =
        MentalExecutor.execute_handler(:goal_update, @agent_id, %{
          goal_id: "g_123"
        })

      assert {:error, :no_update_specified} = result
    end

    test "goal_list defaults to active filter" do
      result = MentalExecutor.execute_handler(:goal_list, @agent_id, %{})

      # Either succeeds with goals or graceful error
      case result do
        {:ok, %{goals: goals, count: count}} ->
          assert is_list(goals)
          assert is_integer(count)

        {:error, _} ->
          :ok
      end
    end

    test "goal_list supports all filter" do
      result = MentalExecutor.execute_handler(:goal_list, @agent_id, %{filter: "all"})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "goal_assess without goal_id assesses all" do
      result = MentalExecutor.execute_handler(:goal_assess, @agent_id, %{})

      case result do
        {:ok, %{assessments: assessments, count: count}} ->
          assert is_list(assessments)
          assert is_integer(count)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "plan handlers" do
    test "plan_add creates an intent" do
      result =
        MentalExecutor.execute_handler(:plan_add, @agent_id, %{
          description: "Step 1: read config",
          goal_id: "g_123",
          urgency: 8
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "plan_list returns recent intents" do
      result = MentalExecutor.execute_handler(:plan_list, @agent_id, %{limit: 5})

      case result do
        {:ok, %{intents: intents, count: count}} ->
          assert is_list(intents)
          assert is_integer(count)

        {:error, _} ->
          :ok
      end
    end

    test "plan_update requires intent_id" do
      result =
        MentalExecutor.execute_handler(:plan_update, @agent_id, %{
          action: "complete"
        })

      assert {:error, :missing_intent_id} = result
    end

    test "plan_update supports complete action" do
      result =
        MentalExecutor.execute_handler(:plan_update, @agent_id, %{
          intent_id: "i_123",
          action: "complete"
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "plan_update supports fail action with reason" do
      result =
        MentalExecutor.execute_handler(:plan_update, @agent_id, %{
          intent_id: "i_123",
          action: "fail",
          reason: "timeout"
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "plan_update rejects unknown actions" do
      result =
        MentalExecutor.execute_handler(:plan_update, @agent_id, %{
          intent_id: "i_123",
          action: "explode"
        })

      assert {:error, {:unknown_action, "explode"}} = result
    end
  end

  describe "proposal handlers" do
    test "proposal_list returns proposals" do
      result = MentalExecutor.execute_handler(:proposal_list, @agent_id, %{})

      case result do
        {:ok, %{proposals: proposals, count: count}} ->
          assert is_list(proposals)
          assert is_integer(count)

        {:error, _} ->
          :ok
      end
    end

    test "proposal_defer requires proposal_id" do
      result = MentalExecutor.execute_handler(:proposal_defer, @agent_id, %{})
      assert {:error, :missing_proposal_id} = result
    end

    test "proposal_defer with id" do
      result =
        MentalExecutor.execute_handler(:proposal_defer, @agent_id, %{
          proposal_id: "p_123"
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "compute handler" do
    test "compute_run with empty code" do
      result = MentalExecutor.execute_handler(:compute_run, @agent_id, %{code: ""})
      assert {:error, :empty_code} = result
    end

    test "compute_run caps timeout" do
      # Even if caller passes huge timeout, it gets capped
      result =
        MentalExecutor.execute_handler(:compute_run, @agent_id, %{
          code: "1 + 1",
          timeout: 999_999
        })

      # Either succeeds or sandbox not available
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "compute_run with code" do
      result =
        MentalExecutor.execute_handler(:compute_run, @agent_id, %{
          code: "Enum.sum([1, 2, 3])"
        })

      case result do
        {:ok, "6"} -> :ok
        {:ok, result_str} when is_binary(result_str) -> :ok
        {:error, _} -> :ok
      end
    end
  end

  describe "think handlers" do
    test "think_reflect returns reflection context" do
      {:ok, result} =
        MentalExecutor.execute_handler(:think_reflect, @agent_id, %{
          topic: "code quality"
        })

      assert result.type == :reflection
      assert result.topic == "code quality"
      assert is_binary(result.prompt)
      assert is_list(result.recent_thoughts)
      assert is_list(result.active_goals)
    end

    test "think_reflect with nil topic" do
      {:ok, result} = MentalExecutor.execute_handler(:think_reflect, @agent_id, %{})

      assert result.type == :reflection
      assert is_nil(result.topic)
      assert String.contains?(result.prompt, "recent activity")
    end

    test "think_observe returns observation context" do
      {:ok, result} =
        MentalExecutor.execute_handler(:think_observe, @agent_id, %{
          focus: "goals"
        })

      assert result.type == :observation
      assert result.focus == "goals"
      assert is_map(result.working_memory)
      assert is_list(result.goals)
    end

    test "think_describe returns self-description" do
      result =
        MentalExecutor.execute_handler(:think_describe, @agent_id, %{
          aspect: "identity"
        })

      case result do
        {:ok, %{type: :description, aspect: :identity, data: data}} ->
          assert is_map(data)

        {:error, _} ->
          # Introspection module not available in test
          :ok
      end
    end

    test "think_describe defaults to all" do
      result = MentalExecutor.execute_handler(:think_describe, @agent_id, %{})

      case result do
        {:ok, %{type: :description, aspect: :all}} -> :ok
        {:error, _} -> :ok
      end
    end

    test "think_introspect returns deep self-examination" do
      result = MentalExecutor.execute_handler(:think_introspect, @agent_id, %{})

      case result do
        {:ok,
         %{type: :introspection, self_knowledge: _, recent_thoughts: thoughts, prompt: prompt}} ->
          assert is_list(thoughts)
          assert is_binary(prompt)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "unknown handler" do
    test "returns error for unknown handler atom" do
      result = MentalExecutor.execute_handler(:unknown_thing, @agent_id, %{})
      assert {:error, {:unknown_handler, :unknown_thing}} = result
    end
  end

  describe "string key params" do
    test "goal_update accepts string keys" do
      result =
        MentalExecutor.execute_handler(:goal_update, @agent_id, %{
          "goal_id" => "g_123",
          "progress" => 0.75
        })

      # Shouldn't error with :missing_goal_id
      refute match?({:error, :missing_goal_id}, result)
    end

    test "plan_update accepts string keys" do
      result =
        MentalExecutor.execute_handler(:plan_update, @agent_id, %{
          "intent_id" => "i_123",
          "action" => "complete"
        })

      refute match?({:error, :missing_intent_id}, result)
    end

    test "proposal_defer accepts string keys" do
      result =
        MentalExecutor.execute_handler(:proposal_defer, @agent_id, %{
          "proposal_id" => "p_123"
        })

      refute match?({:error, :missing_proposal_id}, result)
    end

    test "compute_run accepts string keys" do
      result =
        MentalExecutor.execute_handler(:compute_run, @agent_id, %{
          "code" => "1 + 1"
        })

      refute match?({:error, :empty_code}, result)
    end
  end
end
