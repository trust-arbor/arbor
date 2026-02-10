defmodule Arbor.Orchestrator.Conformance119Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Condition, Context, Outcome}

  test "11.9 supports equals and not-equals comparisons" do
    context = Context.new(%{"context.flag" => "true"})
    outcome = %Outcome{status: :success, preferred_label: "Fix"}

    assert Condition.eval("outcome=success", outcome, context)
    assert Condition.eval("preferred_label=Fix", outcome, context)
    assert Condition.eval("context.flag=true", outcome, context)
    assert Condition.eval("outcome!=fail", outcome, context)
    assert Condition.eval("preferred_label!=Ship", outcome, context)
    refute Condition.eval("outcome=fail", outcome, context)
  end

  test "11.9 supports && conjunction with multiple clauses" do
    context = Context.new(%{"context.tests_passed" => "true", "context.loop_state" => "active"})
    outcome = %Outcome{status: :success, preferred_label: "Approve"}

    assert Condition.eval(
             "outcome=success && context.tests_passed=true && preferred_label=Approve",
             outcome,
             context
           )

    refute Condition.eval(
             "outcome=success && context.tests_passed=false && preferred_label=Approve",
             outcome,
             context
           )
  end

  test "11.9 resolves outcome and preferred_label variables" do
    context = Context.new(%{})
    outcome = %Outcome{status: :partial_success, preferred_label: "Rework"}

    assert Condition.eval("outcome=partial_success", outcome, context)
    assert Condition.eval("preferred_label=Rework", outcome, context)
    refute Condition.eval("preferred_label=Ship", outcome, context)
  end

  test "11.9 resolves context.* values and treats missing keys as empty string" do
    context = Context.new(%{"context.exists" => "yes"})
    outcome = %Outcome{status: :success}

    assert Condition.eval("context.exists=yes", outcome, context)
    assert Condition.eval("context.missing=", outcome, context)
    assert Condition.eval("context.missing!=foo", outcome, context)
    refute Condition.eval("context.missing=foo", outcome, context)
  end

  test "11.9 empty condition evaluates to true" do
    context = Context.new(%{})
    outcome = %Outcome{status: :success}

    assert Condition.eval("", outcome, context)
    assert Condition.eval(nil, outcome, context)
  end
end
