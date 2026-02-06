defmodule Arbor.Consensus.Evaluator.RuleBasedTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Evaluator.RuleBased
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Consensus.Evaluation

  describe "evaluate/3 - common behavior" do
    test "returns a sealed evaluation" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert %Evaluation{} = eval
      assert eval.sealed == true
      assert eval.seal_hash != nil
    end

    test "uses the correct perspective" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :stability)

      assert eval.perspective == :stability
    end

    test "uses the proposal ID" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert eval.proposal_id == proposal.id
    end

    test "accepts custom evaluator_id" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :security, evaluator_id: "custom_eval_1")

      assert eval.evaluator_id == "custom_eval_1"
    end

    test "generates evaluator_id if not provided" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert String.starts_with?(eval.evaluator_id, "eval_security_")
    end
  end

  describe "evaluate/3 - security perspective" do
    test "approves safe code" do
      proposal = TestHelpers.build_proposal(%{new_code: "def safe_function, do: :ok"})
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert eval.vote == :approve
      assert eval.confidence == 0.8
    end

    test "detects System module usage" do
      proposal = TestHelpers.build_proposal(%{new_code: "System.cmd(\"whoami\", [])"})
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "System"))
      assert eval.risk_score > 0
    end

    test "rejects code with System on low-layer target" do
      proposal =
        TestHelpers.build_proposal(%{
          new_code: "System.cmd(\"whoami\", [])",
          target_layer: 1
        })

      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert eval.vote == :reject
    end

    test "detects eval usage" do
      proposal = TestHelpers.build_proposal(%{new_code: "Code.eval_string(code)"})
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "eval"))
    end

    test "rejects code with multiple security concerns" do
      proposal = TestHelpers.build_dangerous_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert eval.vote == :reject
      assert length(eval.concerns) >= 2
    end

    test "detects :os module usage" do
      proposal = TestHelpers.build_proposal(%{new_code: ":os.cmd('whoami')"})
      {:ok, eval} = RuleBased.evaluate(proposal, :security)

      assert Enum.any?(eval.concerns, &String.contains?(&1, ":os"))
      assert eval.risk_score > 0
    end

    test "factors in target layer for risk" do
      low_layer = TestHelpers.build_proposal(%{target_layer: 1, new_code: "def ok, do: :ok"})
      high_layer = TestHelpers.build_proposal(%{target_layer: 4, new_code: "def ok, do: :ok"})

      {:ok, eval_low} = RuleBased.evaluate(low_layer, :security)
      {:ok, eval_high} = RuleBased.evaluate(high_layer, :security)

      # Lower layer should have higher risk
      assert eval_low.risk_score > eval_high.risk_score
    end
  end

  describe "evaluate/3 - stability perspective" do
    test "approves stable code" do
      proposal = TestHelpers.build_proposal(%{new_code: "def hello, do: :world"})
      {:ok, eval} = RuleBased.evaluate(proposal, :stability)

      assert eval.vote == :approve
    end

    test "detects process spawning" do
      proposal = TestHelpers.build_proposal(%{new_code: "spawn(fn -> :ok end)"})
      {:ok, eval} = RuleBased.evaluate(proposal, :stability)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "processes"))
    end

    test "detects Supervisor modifications" do
      proposal =
        TestHelpers.build_proposal(%{new_code: "Supervisor.start_link(children, opts)"})

      {:ok, eval} = RuleBased.evaluate(proposal, :stability)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "supervision tree"))
    end
  end

  describe "evaluate/3 - capability perspective" do
    test "assigns higher benefit to capability changes" do
      cap_proposal = TestHelpers.build_proposal(%{change_type: :capability_change})
      code_proposal = TestHelpers.build_proposal(%{change_type: :code_modification})

      {:ok, cap_eval} = RuleBased.evaluate(cap_proposal, :capability)
      {:ok, code_eval} = RuleBased.evaluate(code_proposal, :capability)

      assert cap_eval.benefit_score > code_eval.benefit_score
    end

    test "raises concerns for governance changes" do
      proposal = TestHelpers.build_proposal(%{change_type: :governance_change})
      {:ok, eval} = RuleBased.evaluate(proposal, :capability)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "Governance"))
    end
  end

  describe "evaluate/3 - adversarial perspective" do
    test "detects bypass patterns" do
      proposal = TestHelpers.build_proposal(%{new_code: "bypass_security()"})
      {:ok, eval} = RuleBased.evaluate(proposal, :adversarial)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "bypass"))
    end

    test "detects override patterns" do
      proposal = TestHelpers.build_proposal(%{new_code: "override_permissions()"})
      {:ok, eval} = RuleBased.evaluate(proposal, :adversarial)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "override"))
    end

    test "approves clean code" do
      proposal = TestHelpers.build_proposal(%{new_code: "def safe, do: :ok"})
      {:ok, eval} = RuleBased.evaluate(proposal, :adversarial)

      assert eval.vote == :approve
    end
  end

  describe "evaluate/3 - resource perspective" do
    test "favors small code" do
      small = TestHelpers.build_proposal(%{new_code: "def f, do: :ok"})
      {:ok, eval} = RuleBased.evaluate(small, :resource)

      assert eval.benefit_score > 0.5
    end

    test "penalizes large code" do
      large_code = String.duplicate("def func_x, do: :ok\n", 200)
      large = TestHelpers.build_proposal(%{new_code: large_code})
      {:ok, eval} = RuleBased.evaluate(large, :resource)

      assert eval.benefit_score <= 0.5
    end
  end

  describe "evaluate/3 - emergence perspective" do
    test "detects autonomous patterns" do
      proposal =
        TestHelpers.build_proposal(%{
          new_code: "Agent.start_link(fn -> :ok end)\nRegistry.lookup(reg, key)"
        })

      {:ok, eval} = RuleBased.evaluate(proposal, :emergence)

      assert eval.benefit_score > 0
    end

    test "abstains on standard code" do
      proposal = TestHelpers.build_proposal(%{new_code: "def hello, do: :world"})
      {:ok, eval} = RuleBased.evaluate(proposal, :emergence)

      assert eval.vote == :abstain
    end
  end

  describe "evaluate/3 - random perspective" do
    test "returns a valid vote" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :random)

      assert eval.vote in [:approve, :reject, :abstain]
      assert eval.confidence > 0
    end
  end

  describe "evaluate/3 - test_runner perspective" do
    test "approves high-coverage test code" do
      proposal =
        TestHelpers.build_proposal(%{
          change_type: :test_change,
          new_code: """
          # my_test.exs _test.exs
          use ExUnit.Case
          describe "test suite" do
          test "case 1" do assert true end
          test "case 2" do refute false end
          test "case 3" do assert 1 == 1 end
          test "case 4" do assert :ok == :ok end
          test "case 5" do refute nil end
          end
          """,
          metadata: %{test_coverage: 0.9}
        })

      {:ok, eval} = RuleBased.evaluate(proposal, :test_runner)

      assert eval.vote == :approve
    end

    test "rejects code without tests" do
      proposal = TestHelpers.build_proposal(%{new_code: "def func, do: :ok"})
      {:ok, eval} = RuleBased.evaluate(proposal, :test_runner)

      assert eval.vote == :reject
    end
  end

  describe "evaluate/3 - code_review perspective" do
    test "approves well-documented code" do
      proposal =
        TestHelpers.build_proposal(%{
          new_code: """
          @moduledoc "Good module"
          @doc "Good function"
          @spec hello() :: :world
          def hello, do: :world
          """
        })

      {:ok, eval} = RuleBased.evaluate(proposal, :code_review)

      assert eval.vote == :approve
    end

    test "detects debug output" do
      proposal =
        TestHelpers.build_proposal(%{new_code: "IO.inspect(data)\nIO.puts(\"debug\")"})

      {:ok, eval} = RuleBased.evaluate(proposal, :code_review)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "Debug output"))
    end

    test "detects technical debt markers" do
      proposal = TestHelpers.build_proposal(%{new_code: "# TODO fix this later"})
      {:ok, eval} = RuleBased.evaluate(proposal, :code_review)

      assert Enum.any?(eval.concerns, &String.contains?(&1, "Technical debt"))
    end
  end

  describe "evaluate/3 - human perspective" do
    test "always abstains" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :human)

      assert eval.vote == :abstain
      assert eval.confidence == 1.0
    end
  end

  describe "evaluate/3 - unknown perspective" do
    test "abstains for unknown perspectives" do
      proposal = TestHelpers.build_proposal()
      {:ok, eval} = RuleBased.evaluate(proposal, :unknown_perspective)

      assert eval.vote == :abstain
      assert eval.confidence == 0.0
    end
  end
end
