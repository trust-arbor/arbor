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
    # Note: `0=0` is FALSE here, not true. Bare "0" isn't a known field
    # (only `outcome`, `preferred_label`, `context.*` resolve), so the
    # LHS becomes "" — which != "0". Filed as
    # `.arbor/roadmap/0-inbox/condition-no-literal-vs-literal.md`.
    # For length scaling we use a known-true clause.

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

  describe "known gaps" do
    test "0=0 is FALSE (no literal-vs-literal comparison support)" do
      # See `.arbor/roadmap/0-inbox/condition-no-literal-vs-literal.md`.
      # An author writing `[condition="1=1"]` to mean "always-true" gets
      # silently-false instead. The fix is either to warn/error on
      # unrecognized field names, or to treat unquoted literals on the
      # LHS as themselves.
      assert Condition.eval("0=0", @outcome, @context) == false
      assert Condition.eval("1=1", @outcome, @context) == false
      assert Condition.eval("true=true", @outcome, @context) == false
    end

    test "unrecognized field name silently resolves to empty string" do
      # `nonexistent_field=anything` → resolve returns "" → "" != "anything" → false
      # No warning, no error. Typos in field names silently produce
      # always-false edges.
      assert Condition.eval("typo_field=anything", @outcome, @context) == false
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
