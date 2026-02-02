defmodule Arbor.Consensus.TestHelpers do
  @moduledoc """
  Test helpers for arbor_consensus tests.

  Provides proposal factories, a test evaluator backend,
  and utility functions for setting up consensus tests.
  """

  alias Arbor.Consensus.Coordinator
  alias Arbor.Consensus.EventStore
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  # ============================================================================
  # Proposal Factories
  # ============================================================================

  @doc """
  Build a valid proposal with defaults.
  """
  def build_proposal(overrides \\ %{}) do
    attrs =
      %{
        proposer: "test_agent_1",
        change_type: :code_modification,
        description: "Test proposal for unit testing",
        target_layer: 4,
        new_code: "defmodule TestModule do\n  def hello, do: :world\nend"
      }
      |> Map.merge(overrides)

    {:ok, proposal} = Proposal.new(attrs)
    proposal
  end

  @doc """
  Build a proposal that uses dangerous patterns (for security testing).
  """
  def build_dangerous_proposal(overrides \\ %{}) do
    build_proposal(
      Map.merge(
        %{
          new_code: """
          defmodule DangerousModule do
            def run do
              System.cmd("rm", ["-rf", "/"])
              File.write!("/etc/passwd", "hacked")
              Code.eval_string("malicious code")
              :os.cmd('whoami')
            end
          end
          """,
          description: "A proposal with security concerns"
        },
        overrides
      )
    )
  end

  @doc """
  Build a governance change proposal (requires supermajority).
  """
  def build_governance_proposal(overrides \\ %{}) do
    build_proposal(
      Map.merge(
        %{
          change_type: :governance_change,
          target_layer: 1,
          description: "Modify governance rules"
        },
        overrides
      )
    )
  end

  @doc """
  Build a documentation change proposal (low-risk).
  """
  def build_doc_proposal(overrides \\ %{}) do
    build_proposal(
      Map.merge(
        %{
          change_type: :documentation_change,
          target_layer: 4,
          description: "Update README documentation",
          new_code: "@moduledoc \"Updated docs\""
        },
        overrides
      )
    )
  end

  @doc """
  Build a proposal with test code.
  """
  def build_test_proposal(overrides \\ %{}) do
    build_proposal(
      Map.merge(
        %{
          change_type: :test_change,
          description: "Add unit tests",
          new_code: """
          # my_module_test.exs
          defmodule MyModuleTest do
            use ExUnit.Case
            @tag :fast

            describe "feature" do
              test "works correctly" do
                assert 1 + 1 == 2
                refute false
              end

              test "handles errors" do
                assert {:error, _} = MyModule.bad_call()
                assert_receive :done, 1000
                refute MyModule.broken?()
              end

              test "edge cases" do
                assert MyModule.edge(nil) == :ok
                refute is_nil(MyModule.edge(:val))
                assert match?(%{ok: true}, MyModule.result())
              end
            end
          end
          """
        },
        overrides
      )
    )
  end

  @doc """
  Build a proposal that violates invariants.
  """
  def build_invariant_violating_proposal(overrides \\ %{}) do
    build_proposal(
      Map.merge(
        %{
          new_code: "quorum = 0\nbypass_boundary\nclear_log\nremove_layer",
          description: "Proposal that violates invariants"
        },
        overrides
      )
    )
  end

  # ============================================================================
  # Sealed Evaluation Factory
  # ============================================================================

  @doc """
  Build a sealed evaluation.
  """
  def build_evaluation(overrides \\ %{}) do
    attrs =
      %{
        proposal_id: "prop_test_123",
        evaluator_id: "eval_test_1",
        perspective: :security,
        vote: :approve,
        reasoning: "Test evaluation",
        confidence: 0.8,
        concerns: [],
        recommendations: [],
        risk_score: 0.2,
        benefit_score: 0.7
      }
      |> Map.merge(overrides)

    {:ok, eval} = Evaluation.new(attrs)
    Evaluation.seal(eval)
  end

  @doc """
  Build a set of evaluations that result in approval.
  """
  def build_approving_evaluations(proposal_id, count \\ 5) do
    perspectives = [:security, :stability, :capability, :adversarial, :resource, :emergence, :random]

    perspectives
    |> Enum.take(count)
    |> Enum.map(fn perspective ->
      build_evaluation(%{
        proposal_id: proposal_id,
        evaluator_id: "eval_#{perspective}_test",
        perspective: perspective,
        vote: :approve,
        confidence: 0.8
      })
    end)
  end

  @doc """
  Build a set of evaluations that result in rejection.
  """
  def build_rejecting_evaluations(proposal_id, count \\ 5) do
    perspectives = [:security, :stability, :capability, :adversarial, :resource, :emergence, :random]

    perspectives
    |> Enum.take(count)
    |> Enum.map(fn perspective ->
      build_evaluation(%{
        proposal_id: proposal_id,
        evaluator_id: "eval_#{perspective}_test",
        perspective: perspective,
        vote: :reject,
        reasoning: "Rejected due to concerns",
        confidence: 0.9,
        risk_score: 0.8
      })
    end)
  end

  # ============================================================================
  # Test Evaluator Backend
  # ============================================================================

  defmodule AlwaysApproveBackend do
    @moduledoc false
    @behaviour Arbor.Consensus.EvaluatorBackend

    @impl true
    def evaluate(proposal, perspective, opts) do
      evaluator_id = Keyword.get(opts, :evaluator_id, "eval_#{perspective}_approve")

      {:ok, eval} =
        Evaluation.new(%{
          proposal_id: proposal.id,
          evaluator_id: evaluator_id,
          perspective: perspective,
          vote: :approve,
          reasoning: "Auto-approved by test backend",
          confidence: 0.9,
          risk_score: 0.1,
          benefit_score: 0.9
        })

      {:ok, Evaluation.seal(eval)}
    end
  end

  defmodule AlwaysRejectBackend do
    @moduledoc false
    @behaviour Arbor.Consensus.EvaluatorBackend

    @impl true
    def evaluate(proposal, perspective, opts) do
      evaluator_id = Keyword.get(opts, :evaluator_id, "eval_#{perspective}_reject")

      {:ok, eval} =
        Evaluation.new(%{
          proposal_id: proposal.id,
          evaluator_id: evaluator_id,
          perspective: perspective,
          vote: :reject,
          reasoning: "Auto-rejected by test backend",
          confidence: 0.9,
          concerns: ["Test concern"],
          risk_score: 0.9,
          benefit_score: 0.1
        })

      {:ok, Evaluation.seal(eval)}
    end
  end

  defmodule FailingBackend do
    @moduledoc false
    @behaviour Arbor.Consensus.EvaluatorBackend

    @impl true
    def evaluate(_proposal, _perspective, _opts) do
      {:error, :intentional_failure}
    end
  end

  defmodule SlowBackend do
    @moduledoc false
    @behaviour Arbor.Consensus.EvaluatorBackend

    @impl true
    def evaluate(_proposal, _perspective, _opts) do
      Process.sleep(60_000)
      {:error, :should_have_timed_out}
    end
  end

  # ============================================================================
  # Test Event Sink
  # ============================================================================

  defmodule TestEventSink do
    @moduledoc false
    @behaviour Arbor.Consensus.EventSink

    @impl true
    def record(event) do
      send(Process.whereis(:test_event_sink_receiver) || self(), {:event_sink, event})
      :ok
    end
  end

  # ============================================================================
  # Test Authorizer
  # ============================================================================

  defmodule AllowAllAuthorizer do
    @moduledoc false
    @behaviour Arbor.Consensus.Authorizer

    @impl true
    def authorize_proposal(_proposal), do: :ok

    @impl true
    def authorize_execution(_proposal, _decision), do: :ok
  end

  defmodule DenyAllAuthorizer do
    @moduledoc false
    @behaviour Arbor.Consensus.Authorizer

    @impl true
    def authorize_proposal(_proposal), do: {:error, :unauthorized}

    @impl true
    def authorize_execution(_proposal, _decision), do: {:error, :unauthorized}
  end

  # ============================================================================
  # Test Executor
  # ============================================================================

  defmodule TestExecutor do
    @moduledoc false
    @behaviour Arbor.Consensus.Executor

    @impl true
    def execute(_proposal, _decision) do
      send(Process.whereis(:test_executor_receiver) || self(), :executed)
      {:ok, :executed}
    end
  end

  # ============================================================================
  # Test Event Log (for recovery testing)
  # ============================================================================

  defmodule TestEventLog do
    @moduledoc false

    def start(events \\ []) do
      table = :ets.new(:test_event_log, [:set, :public])
      :ets.insert(table, {"arbor:consensus", events})
      table
    end

    def read_stream(stream_id, opts) do
      table = Keyword.fetch!(opts, :table)

      case :ets.lookup(table, stream_id) do
        [{^stream_id, events}] -> {:ok, events}
        [] -> {:error, :stream_not_found}
      end
    end

    def append(_stream_id, event_or_events, _opts) do
      events = List.wrap(event_or_events)
      {:ok, events}
    end
  end

  # ============================================================================
  # Failing Executor (for execution failure testing)
  # ============================================================================

  defmodule FailingExecutor do
    @moduledoc false
    @behaviour Arbor.Consensus.Executor

    @impl true
    def execute(_proposal, _decision) do
      {:error, :execution_failed}
    end
  end

  # ============================================================================
  # Test Advisory Evaluator (implements Evaluator behaviour)
  # ============================================================================

  defmodule TestAdvisoryEvaluator do
    @moduledoc false
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :test_advisory

    @impl true
    def perspectives, do: [:brainstorming, :design_review]

    @impl true
    def strategy, do: :deterministic

    @impl true
    def evaluate(proposal, perspective, _opts) do
      {:ok, eval} =
        Evaluation.new(%{
          proposal_id: proposal.id,
          evaluator_id: "test_advisory_#{perspective}",
          perspective: perspective,
          vote: :approve,
          reasoning: "Test analysis from #{perspective} for: #{proposal.description}",
          confidence: 0.7
        })

      {:ok, Evaluation.seal(eval)}
    end
  end

  defmodule FailingAdvisoryEvaluator do
    @moduledoc false
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :failing_advisory

    @impl true
    def perspectives, do: [:brainstorming]

    @impl true
    def evaluate(_proposal, _perspective, _opts) do
      {:error, :intentional_failure}
    end
  end

  # ============================================================================
  # Mock AI Module (for advisory LLM testing)
  # ============================================================================

  defmodule MockAI do
    @moduledoc false

    def generate_text(_prompt, _opts) do
      {:ok,
       %{
         text:
           Jason.encode!(%{
             "analysis" => "Mock analysis of the design question",
             "considerations" => ["Consider simplicity", "Consider composability"],
             "alternatives" => ["Alternative approach A", "Alternative approach B"],
             "recommendation" => "Start with the simplest approach"
           }),
         model: "mock-model",
         provider: :mock,
         usage: %{input_tokens: 100, output_tokens: 200}
       }}
    end
  end

  defmodule ErrorAI do
    @moduledoc false

    def generate_text(_prompt, _opts) do
      {:error, :api_error}
    end
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  @doc """
  Start a fresh coordinator for testing.
  Returns the coordinator pid.
  """
  def start_test_coordinator(opts \\ []) do
    # Use a guaranteed-unique name to avoid conflicts across async tests
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = Keyword.get(opts, :name, :"test_coordinator_#{System.unique_integer([:positive])}")

    default_opts = [
      name: name,
      evaluator_backend: AlwaysApproveBackend,
      config: [evaluation_timeout_ms: 5_000]
    ]

    merged = Keyword.merge(default_opts, opts)
    {:ok, pid} = Coordinator.start_link(merged)
    {pid, name}
  end

  @doc """
  Start a fresh event store for testing.
  Returns the event store pid.
  """
  def start_test_event_store(opts \\ []) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = Keyword.get(opts, :table_name, :"test_events_#{System.unique_integer([:positive])}")
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = Keyword.get(opts, :name, :"test_event_store_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      EventStore.start_link(
        Keyword.merge(opts, name: name, table_name: table_name)
      )

    {pid, name}
  end

  @doc """
  Wait for a proposal to reach a terminal status.
  """
  def wait_for_decision(coordinator, proposal_id, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_decision(coordinator, proposal_id, deadline)
  end

  defp do_wait_for_decision(coordinator, proposal_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case Coordinator.get_status(proposal_id, coordinator) do
        {:ok, status} when status in [:approved, :rejected, :deadlock, :vetoed] ->
          {:ok, status}

        {:ok, _} ->
          Process.sleep(50)
          do_wait_for_decision(coordinator, proposal_id, deadline)

        error ->
          error
      end
    end
  end
end
