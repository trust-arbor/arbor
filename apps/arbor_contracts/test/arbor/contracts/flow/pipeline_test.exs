defmodule Arbor.Contracts.Flow.PipelineTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Flow.Pipeline

  @moduletag :fast

  # Define a test pipeline for testing the helper functions
  defmodule TestPipeline do
    @behaviour Pipeline

    @impl true
    def stages, do: [:inbox, :brainstorming, :planned, :in_progress, :completed, :discarded]

    @impl true
    def initial_stage, do: :inbox

    @impl true
    def terminal_stages, do: [:completed, :discarded]

    @impl true
    def transition_allowed?(:inbox, :brainstorming), do: true
    def transition_allowed?(:brainstorming, :planned), do: true
    def transition_allowed?(:brainstorming, :discarded), do: true
    def transition_allowed?(:planned, :in_progress), do: true
    def transition_allowed?(:planned, :discarded), do: true
    def transition_allowed?(:in_progress, :completed), do: true
    def transition_allowed?(:in_progress, :planned), do: true
    def transition_allowed?(_, _), do: false

    @impl true
    def stage_directory(:inbox), do: "0-inbox"
    def stage_directory(:brainstorming), do: "1-brainstorming"
    def stage_directory(:planned), do: "2-planned"
    def stage_directory(:in_progress), do: "3-in_progress"
    def stage_directory(:completed), do: "4-completed"
    def stage_directory(:discarded), do: "8-discarded"
  end

  describe "valid_stage?/2" do
    test "returns true for valid stage" do
      assert Pipeline.valid_stage?(TestPipeline, :inbox)
      assert Pipeline.valid_stage?(TestPipeline, :completed)
    end

    test "returns false for invalid stage" do
      refute Pipeline.valid_stage?(TestPipeline, :nonexistent)
    end
  end

  describe "terminal?/2" do
    test "returns true for terminal stages" do
      assert Pipeline.terminal?(TestPipeline, :completed)
      assert Pipeline.terminal?(TestPipeline, :discarded)
    end

    test "returns false for non-terminal stages" do
      refute Pipeline.terminal?(TestPipeline, :inbox)
      refute Pipeline.terminal?(TestPipeline, :planned)
    end
  end

  describe "validate_transition/3" do
    test "returns :ok for valid transitions" do
      assert :ok = Pipeline.validate_transition(TestPipeline, :inbox, :brainstorming)
      assert :ok = Pipeline.validate_transition(TestPipeline, :brainstorming, :planned)
      assert :ok = Pipeline.validate_transition(TestPipeline, :in_progress, :completed)
    end

    test "returns error for invalid transitions" do
      assert {:error, :invalid_transition} =
               Pipeline.validate_transition(TestPipeline, :inbox, :completed)

      assert {:error, :invalid_transition} =
               Pipeline.validate_transition(TestPipeline, :completed, :inbox)
    end

    test "returns error for unknown stages" do
      assert {:error, :unknown_stage} =
               Pipeline.validate_transition(TestPipeline, :nonexistent, :inbox)

      assert {:error, :unknown_stage} =
               Pipeline.validate_transition(TestPipeline, :inbox, :nonexistent)
    end
  end

  describe "valid_next_stages/2" do
    test "returns valid next stages" do
      assert [:brainstorming] = Pipeline.valid_next_stages(TestPipeline, :inbox)
      assert [:discarded, :planned] = Pipeline.valid_next_stages(TestPipeline, :brainstorming) |> Enum.sort()
      assert [:completed, :planned] = Pipeline.valid_next_stages(TestPipeline, :in_progress) |> Enum.sort()
    end

    test "returns empty list for terminal stages" do
      assert [] = Pipeline.valid_next_stages(TestPipeline, :completed)
      assert [] = Pipeline.valid_next_stages(TestPipeline, :discarded)
    end
  end

  describe "TestPipeline implementation" do
    test "stages returns all stages" do
      stages = TestPipeline.stages()
      assert length(stages) == 6
      assert :inbox in stages
      assert :completed in stages
    end

    test "initial_stage returns inbox" do
      assert TestPipeline.initial_stage() == :inbox
    end

    test "terminal_stages returns completed and discarded" do
      terminals = TestPipeline.terminal_stages()
      assert :completed in terminals
      assert :discarded in terminals
    end

    test "stage_directory returns correct directories" do
      assert "0-inbox" = TestPipeline.stage_directory(:inbox)
      assert "2-planned" = TestPipeline.stage_directory(:planned)
      assert "4-completed" = TestPipeline.stage_directory(:completed)
    end

    test "transition_allowed? follows the pipeline graph" do
      # Valid forward transitions
      assert TestPipeline.transition_allowed?(:inbox, :brainstorming)
      assert TestPipeline.transition_allowed?(:brainstorming, :planned)
      assert TestPipeline.transition_allowed?(:planned, :in_progress)
      assert TestPipeline.transition_allowed?(:in_progress, :completed)

      # Valid discard transitions
      assert TestPipeline.transition_allowed?(:brainstorming, :discarded)
      assert TestPipeline.transition_allowed?(:planned, :discarded)

      # Valid back transition (in_progress -> planned for blocking issues)
      assert TestPipeline.transition_allowed?(:in_progress, :planned)

      # Invalid transitions
      refute TestPipeline.transition_allowed?(:inbox, :completed)
      refute TestPipeline.transition_allowed?(:completed, :inbox)
      refute TestPipeline.transition_allowed?(:planned, :inbox)
    end
  end
end
