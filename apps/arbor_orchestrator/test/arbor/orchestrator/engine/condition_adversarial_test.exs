defmodule Arbor.Orchestrator.Engine.ConditionAdversarialTest do
  @moduledoc """
  Adversarial inputs to the edge condition parser/evaluator.

  Two surfaces:

    * `Arbor.Orchestrator.Engine.Condition.eval/3` — runtime evaluator,
      hit on every edge traversal.
    * `Arbor.Orchestrator.Engine.Condition.valid_syntax?/1` — validator,
      hit by `mix arbor.pipeline.validate` and the IR compiler.
    * `Arbor.Orchestrator.Graph.Edge.parse_condition/1` — compile-time
      tuple parser, hit when the IR compiler builds the edge.

  All three are reached from agent-authored DOT text. If they're slow,
  crash, or backtrack catastrophically on crafted input, a malicious or
  hallucinating DOT can DoS the engine before any work runs.

  Each test asserts: the call returns within a sane budget, doesn't
  crash, and produces a deterministic boolean / tuple / boolean.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Condition
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Graph.Edge

  @outcome %Outcome{status: :success, preferred_label: "test"}
  @context Context.new(%{"a" => 1, "b" => 2, "foo" => "bar"})

  defp call_within(fun, timeout_ms \\ 2_000) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        flunk("Call did not return within #{timeout_ms}ms — likely DoS or infinite loop")
    end
  end

  # ── Length scaling ─────────────────────────────────────────────────

  describe "length scaling (linear, not catastrophic)" do
    test "1000 trivially-true clauses" do
      cond_str = String.duplicate("outcome=success && ", 1000) <> "outcome=success"

      # Both parser and evaluator should handle this in single-digit ms.
      result_eval = call_within(fn -> Condition.eval(cond_str, @outcome, @context) end)
      assert result_eval == true

      result_parse = call_within(fn -> Edge.parse_condition(cond_str) end)
      assert match?({:and, _}, result_parse)
    end

    test "10000 trivially-true clauses" do
      cond_str = String.duplicate("outcome=success && ", 10_000) <> "outcome=success"

      # Still linear: ~10k String.split + ~70k String.contains? per call.
      # On a modern machine this should be well under a second.
      assert call_within(fn -> Condition.eval(cond_str, @outcome, @context) end) == true
      assert match?({:and, _}, call_within(fn -> Edge.parse_condition(cond_str) end))
    end

    test "1000 clauses where the LAST one is false (full traversal)" do
      cond_str = String.duplicate("outcome=success && ", 999) <> "outcome=fail"
      assert call_within(fn -> Condition.eval(cond_str, @outcome, @context) end) == false
    end

    test "long single clause (no &&) — 100k char LHS" do
      big_key = "context." <> String.duplicate("a", 100_000)
      cond_str = big_key <> "=anything"

      # eval should be fast (just String.split + Context.get lookup of a
      # huge missing key).
      assert call_within(fn -> Condition.eval(cond_str, @outcome, @context) end) in [
               true,
               false
             ]
    end

    test "valid_syntax? on a 100k-char key" do
      # The validator uses a regex anchored on both ends — no backtracking.
      big_key = "context." <> String.duplicate("a", 100_000)
      cond_str = big_key <> "=x"

      assert call_within(fn -> Condition.valid_syntax?(cond_str) end) in [true, false]
    end
  end

  # ── Operator confusion ────────────────────────────────────────────

  describe "operator confusion" do
    test "many = signs in one clause: only the first split wins" do
      # `a=b=c=d` parses as `a` == `b=c=d` (String.split with parts: 2).
      assert is_boolean(Condition.eval("a=b=c=d", @outcome, @context))
    end

    test "!= and = together: != wins (checked first in cond)" do
      assert is_boolean(Condition.eval("foo!=bar=baz", @outcome, @context))
    end

    test "operator-only clause" do
      assert is_boolean(Condition.eval("=========", @outcome, @context))
      assert is_boolean(Condition.eval("!=!=!=!=", @outcome, @context))
      assert is_boolean(Condition.eval(">=>=>=", @outcome, @context))
    end

    test "clause with no operator at all" do
      # Doesn't match any String.contains? branch → returns false.
      assert Condition.eval("just_an_identifier_no_operator", @outcome, @context) == false
    end
  end

  # ── Empty / whitespace clauses ────────────────────────────────────

  describe "empty and whitespace clauses" do
    test "empty string" do
      assert Condition.eval("", @outcome, @context) == true
      assert Condition.eval(nil, @outcome, @context) == true
    end

    test "only && separators" do
      # Each empty clause gets filtered by Enum.reject, leaving nothing.
      assert Condition.eval("&&&&&&", @outcome, @context) == true
    end

    test "leading/trailing &&" do
      assert is_boolean(Condition.eval("&& outcome=success &&", @outcome, @context))
    end

    test "interleaved empty clauses" do
      assert Condition.eval("&& outcome=success &&  && outcome=success", @outcome, @context) ==
               true
    end
  end

  # ── Catastrophic regex attempts ───────────────────────────────────

  describe "valid_syntax? regex robustness" do
    # The regex is ^[A-Za-z_][A-Za-z0-9_.]*$ — anchored both ends, no
    # alternation, no backtracking surface. Adversarial inputs should
    # short-circuit fast.

    test "all-dots key" do
      assert call_within(fn -> Condition.valid_syntax?("context......=x") end) in [true, false]
    end

    test "key with operator chars (should reject quickly)" do
      assert call_within(fn -> Condition.valid_syntax?("context.foo!bar=x") end) in [true, false]
    end

    test "key with unicode" do
      assert call_within(fn -> Condition.valid_syntax?("context.βαβα=x") end) in [true, false]
    end

    test "10k clauses of valid_syntax check" do
      cond_str = String.duplicate("context.a.b=v && ", 10_000) <> "0=0"
      assert call_within(fn -> Condition.valid_syntax?(cond_str) end) in [true, false]
    end
  end

  # ── Numeric coercion edge cases ───────────────────────────────────

  describe "to_number coercion (used by >, <, >=, <=)" do
    test "non-numeric LHS in > comparison" do
      assert is_boolean(Condition.eval("preferred_label > 5", @outcome, @context))
    end

    test "very long numeric string" do
      big_num = String.duplicate("9", 1000) <> "=" <> String.duplicate("9", 1000)
      assert is_boolean(Condition.eval(big_num, @outcome, @context))
    end

    test "scientific notation? (probably not honored, but shouldn't crash)" do
      assert is_boolean(Condition.eval("preferred_label > 1e308", @outcome, @context))
    end
  end

  # ── Parse_condition (compile-time tuple shape) ────────────────────

  describe "Edge.parse_condition tuple production" do
    test "10k clauses produces an {:and, list} of that length" do
      cond_str = String.duplicate("0=0 && ", 10_000) <> "0=0"
      result = call_within(fn -> Edge.parse_condition(cond_str) end)

      assert {:and, clauses} = result
      # 10001 clauses (10k duplicates + final one), but Enum.reject
      # filters any empty strings caused by trailing &&. We just confirm
      # it's a large list.
      assert length(clauses) >= 10_000
    end

    test "single clause produces a single tuple, not a wrapped list" do
      assert {:eq, "a", "1"} = Edge.parse_condition("a=1")
    end

    test "operator-only string parses as eq with empty LHS (current behavior)" do
      # `==========` String.split-s on first `=`, giving `""` and
      # `"========="`. So it parses as `{:eq, "", "========="}`, NOT
      # :parse_error. Pinned to surface any future tightening.
      assert {:eq, "", "========="} = Edge.parse_condition("==========")
    end

    test "clause with no operator parses to :parse_error" do
      assert {:parse_error, _} = Edge.parse_condition("nothing_to_match_here")
    end
  end

  # ── Known gaps (current behavior — pin so a fix shows up as a diff) ─

  describe "LHS literals + typo defense (fixed)" do
    # Fix: resolve/3 now recognizes numeric and quoted literals on the
    # LHS, and warns loudly when a bareword falls through to the
    # catch-all. Validation via `mix arbor.pipeline.validate` rejects
    # bareword typos at compile time; the runtime warning is the
    # defense-in-depth for un-validated pipelines.

    test "numeric literal LHS evaluates as itself: 0=0, 1=1, -3=-3 are TRUE" do
      assert Condition.eval("0=0", @outcome, @context) == true
      assert Condition.eval("1=1", @outcome, @context) == true
      assert Condition.eval("-3=-3", @outcome, @context) == true
      assert Condition.eval("1.5=1.5", @outcome, @context) == true
    end

    test "numeric literal comparisons across operators work as expected" do
      assert Condition.eval("3>2", @outcome, @context) == true
      assert Condition.eval("2>3", @outcome, @context) == false
      assert Condition.eval("3>=3", @outcome, @context) == true
      assert Condition.eval("1!=2", @outcome, @context) == true
    end

    test "quoted literal LHS: \"red\"=\"red\" is TRUE, \"red\"=\"blue\" is FALSE" do
      assert Condition.eval(~s("red"="red"), @outcome, @context) == true
      assert Condition.eval(~s("red"="blue"), @outcome, @context) == false
    end

    test "bareword identifier (typo) still resolves to \"\" but now warns loudly" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Condition.eval("typo_field=x", @outcome, @context)
        end)

      assert log =~ "[Condition]"
      assert log =~ "typo_field"
      assert log =~ "unknown LHS"
    end

    test "`true=true` bareword on both sides still false (intentional — use quotes for literal strings)" do
      # `true` and `false` look like field names, not literals. If you
      # want literal-string comparison use quotes: `"true"="true"`.
      # The warning fires here too.
      log =
        ExUnit.CaptureLog.capture_log(fn -> Condition.eval("true=true", @outcome, @context) end)

      assert log =~ "unknown LHS"
    end

    test "valid_syntax? accepts numeric and quoted literals on LHS" do
      assert Condition.valid_syntax?("0=0")
      assert Condition.valid_syntax?("1.5>0")
      assert Condition.valid_syntax?(~s("red"="red"))
    end

    test "valid_syntax? still rejects bareword LHS that isn't a known field (typo defense)" do
      refute Condition.valid_syntax?("preffered_label=approve")
      refute Condition.valid_syntax?("typo_field=anything")
    end
  end

  # ── Combined-surface (DOT compile + condition eval) ──────────────

  describe "DOT with adversarial condition (end-to-end)" do
    test "DOT with 1000-clause edge condition compiles and runs in bounded time" do
      cond_str = String.duplicate("0=0 && ", 1000) <> "0=0"

      dot = """
      digraph G {
        graph [goal="adversarial edge condition"]
        start [shape=Mdiamond]
        gate [type="gate", shape=diamond, predicate="expression", expression="0=0"]
        exit [shape=Msquare]
        start -> gate
        gate -> exit [condition="#{cond_str}"]
      }
      """

      logs_root =
        Path.join(System.tmp_dir!(), "arbor_cond_adv_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(logs_root) end)

      result =
        call_within(
          fn ->
            Arbor.Orchestrator.run(dot, logs_root: logs_root, authorization: false)
          end,
          5_000
        )

      # We don't care whether validator rejects the condition or the
      # engine runs through it — only that we get a deterministic
      # answer in bounded time.
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
