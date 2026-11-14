defmodule Arbor.Orchestrator.Session.RefusalDiagnosticTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Session.RefusalDiagnostic

  @secret "hi, here is my private note"

  test "a returned reason keeps its atoms, so the cause is named" do
    assert RefusalDiagnostic.describe_reason(:capability_mutation_unauthorized) ==
             ":capability_mutation_unauthorized"

    assert RefusalDiagnostic.describe_reason({:session_error, :disclosure_issue_failed}) ==
             "{:session_error, :disclosure_issue_failed}"
  end

  test "strings, maps and lists are reduced to their size" do
    reason = {:error, @secret, %{"session.input" => @secret}, [@secret, @secret]}
    text = RefusalDiagnostic.describe_reason(reason)

    refute text =~ "private note"
    refute text =~ "session.input"
    assert text == "{:error, <binary 27 bytes>, <map 1 keys>, <list 2 items>}"
  end

  test "a data-carrying exception is named with the shape of its term, not its message" do
    exception = %MatchError{term: {:error, %{"session.input" => @secret}}}
    text = RefusalDiagnostic.describe(:error, exception, [])

    assert text == "MatchError {:error, <map 1 keys>}"
    refute text =~ "private note"

    assert RefusalDiagnostic.describe(:error, %KeyError{key: :route, term: %{a: @secret}}, []) ==
             "KeyError key=:route"

    assert RefusalDiagnostic.describe(:error, %RuntimeError{message: @secret}, []) ==
             "RuntimeError"
  end

  test "a code-built message is kept" do
    exception = %UndefinedFunctionError{module: Nope, function: :missing, arity: 1}
    assert RefusalDiagnostic.describe(:error, exception, []) =~ "UndefinedFunctionError: "
    assert RefusalDiagnostic.describe(:error, exception, []) =~ "Nope.missing/1"
  end

  test "stack frames carry module, function and arity, never arguments" do
    stacktrace = [
      {Arbor.Orchestrator.Session, :do_prepare_live_turn, [@secret, :b],
       [file: ~c"lib/arbor/orchestrator/session.ex", line: 3300]},
      {Arbor.Orchestrator.Session.TurnEgress, :issue_disclosure_if_needed, 4,
       [file: ~c"lib/arbor/orchestrator/session/turn_egress.ex", line: 487]},
      {Kernel, :apply, 3, []},
      {Kernel, :not_shown, 0, []}
    ]

    text = RefusalDiagnostic.describe(:throw, {:halt, @secret}, stacktrace)

    assert text =~ "throw {:halt, <binary 27 bytes>} at "
    assert text =~ "Arbor.Orchestrator.Session.do_prepare_live_turn/2"
    assert text =~ "session.ex:3300"
    assert text =~ "TurnEgress.issue_disclosure_if_needed/4"
    refute text =~ "private note"
    refute text =~ "not_shown"
  end

  test "exits and deep or wide terms stay bounded" do
    deep = Enum.reduce(1..20, :leaf, fn _, acc -> {:wrap, acc} end)
    assert RefusalDiagnostic.describe(:exit, deep, :not_a_stacktrace) =~ "{...2}"

    wide = List.to_tuple(Enum.to_list(1..50))
    assert RefusalDiagnostic.describe_reason(wide) == "{1, 2, 3, 4, ...}"

    long = Enum.map(1..40, fn _ -> {Arbor.Orchestrator.Session, :f, 9, [file: ~c"x.ex"]} end)
    assert String.length(RefusalDiagnostic.describe(:error, %ArgumentError{}, long)) <= 601
  end
end
