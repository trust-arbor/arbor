# Mock AI modules for SDLC testing
# These are compiled via test/support and available to all tests
#
# These modules mimic the Arbor.AI.generate_text/2 interface:
#   generate_text(prompt, opts) :: {:ok, %{text: ..., model: ..., provider: ..., usage: ...}} | {:error, reason}

# =============================================================================
# Generic MockAI for Expander tests
# =============================================================================

defmodule MockAI.ExpansionResponse do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    response = %{
      "priority" => "high",
      "category" => "feature",
      "effort" => "medium",
      "summary" => "Implement comprehensive user authentication system",
      "why_it_matters" =>
        "User authentication is fundamental for security and personalized experiences",
      "acceptance_criteria" => [
        "Users can register with email and password",
        "Users can log in with valid credentials",
        "Users can log out and end their session"
      ],
      "definition_of_done" => [
        "All tests pass",
        "Documentation updated",
        "Code reviewed"
      ]
    }

    {:ok, %{text: Jason.encode!(response), model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule MockAI.FailureResponse do
  @moduledoc false

  @reason :connection_error

  def set_reason(reason) do
    # Store in process dictionary for this test
    Process.put(:mock_ai_failure_reason, reason)
  end

  def generate_text(_prompt, _opts) do
    reason = Process.get(:mock_ai_failure_reason, @reason)
    {:error, reason}
  end
end

defmodule MockAI.MalformedResponse do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    {:ok, %{text: "not valid json at all", model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule MockAI do
  @moduledoc false

  def create_expansion_response do
    MockAI.ExpansionResponse
  end

  def create_expansion_response(overrides) when is_map(overrides) do
    # For now, just return the standard module
    MockAI.ExpansionResponse
  end

  def create_expansion_response(overrides) when is_list(overrides) do
    # For now, just return the standard module (overrides not implemented yet)
    MockAI.ExpansionResponse
  end

  def create_failure_response(reason) do
    MockAI.FailureResponse.set_reason(reason)
    MockAI.FailureResponse
  end

  def create_malformed_response do
    MockAI.MalformedResponse
  end
end

# =============================================================================
# EvaluatorMockAI for Evaluator tests
# =============================================================================

defmodule EvaluatorMockAI.StandardApprove do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    response = %{
      "vote" => "approve",
      "reasoning" =>
        "The proposal is well-defined with clear acceptance criteria and appropriate scope.",
      "concerns" => [],
      "recommendations" => ["Consider adding more edge case tests"]
    }

    {:ok, %{text: Jason.encode!(response), model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule EvaluatorMockAI.StandardReject do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    response = %{
      "vote" => "reject",
      "reasoning" => "The proposal has significant risks that need to be addressed.",
      "concerns" => ["Security implications not addressed", "Missing error handling strategy"],
      "recommendations" => ["Add security review", "Define error handling approach"]
    }

    {:ok, %{text: Jason.encode!(response), model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule EvaluatorMockAI.MalformedApprove do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    # Return non-JSON but with detectable vote
    text = """
    After reviewing the proposal, I approve this change.
    The implementation looks solid and well-thought-out.
    """

    {:ok, %{text: text, model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule EvaluatorMockAI.Failure do
  @moduledoc false

  @reason :connection_error

  def set_reason(reason) do
    Process.put(:evaluator_mock_ai_failure_reason, reason)
  end

  def generate_text(_prompt, _opts) do
    reason = Process.get(:evaluator_mock_ai_failure_reason, @reason)
    {:error, reason}
  end
end

defmodule EvaluatorMockAI.Timeout do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    # Simulate a long operation
    Process.sleep(1000)
    {:ok, %{text: "This should timeout", model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule EvaluatorMockAI do
  @moduledoc false

  def standard_approve do
    EvaluatorMockAI.StandardApprove
  end

  def standard_reject_with_concerns do
    EvaluatorMockAI.StandardReject
  end

  def malformed_json_approve do
    EvaluatorMockAI.MalformedApprove
  end

  def failure(reason) do
    EvaluatorMockAI.Failure.set_reason(reason)
    EvaluatorMockAI.Failure
  end

  def timeout do
    EvaluatorMockAI.Timeout
  end
end

# =============================================================================
# DeliberatorMockAI for Deliberator tests
# =============================================================================

defmodule DeliberatorMockAI.WellSpecified do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    # Returns a response indicating the item is well-specified
    response = %{
      "needs_decisions" => false,
      "decision_points" => [],
      "is_well_specified" => true,
      "overall_assessment" => "This item has clear requirements and is ready for planning."
    }

    {:ok, %{text: Jason.encode!(response), model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule DeliberatorMockAI.NeedsDecision do
  @moduledoc false

  def generate_text(_prompt, _opts) do
    # Returns a response indicating decisions are needed
    response = %{
      "needs_decisions" => true,
      "decision_points" => [
        %{
          "question" => "Which database should we use?",
          "options" => ["PostgreSQL", "SQLite", "MySQL"],
          "context" => "Need to choose based on scalability requirements"
        }
      ],
      "is_well_specified" => false,
      "overall_assessment" => "Item needs architectural decisions before proceeding."
    }

    {:ok, %{text: Jason.encode!(response), model: "mock", provider: :mock, usage: %{}}}
  end
end

defmodule DeliberatorMockAI.Failure do
  @moduledoc false

  @reason :connection_error

  def set_reason(reason) do
    Process.put(:deliberator_mock_ai_failure_reason, reason)
  end

  def generate_text(_prompt, _opts) do
    reason = Process.get(:deliberator_mock_ai_failure_reason, @reason)
    {:error, reason}
  end
end

defmodule DeliberatorMockAI do
  @moduledoc false

  def well_specified do
    DeliberatorMockAI.WellSpecified
  end

  def needs_decision do
    DeliberatorMockAI.NeedsDecision
  end

  def failure(reason) do
    DeliberatorMockAI.Failure.set_reason(reason)
    DeliberatorMockAI.Failure
  end
end
