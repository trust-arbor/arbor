defmodule Arbor.Agent.Eval.SecurityReview.JudgeTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.SecurityReview.Judge

  defp finding(attrs \\ %{}),
    do:
      Map.merge(
        %{
          category: "serialization_drop",
          title: "Taint provenance lost on resume",
          file: "context.ex",
          line: 239,
          rationale: "dropped"
        },
        attrs
      )

  defp label(attrs \\ %{}),
    do:
      Map.merge(
        %{
          category: "fail_open_authz",
          invariant: "taint must persist across resume",
          files: ["context.ex"]
        },
        attrs
      )

  defp stub(reply), do: fn _o -> {:ok, reply} end

  test "credits a semantic match even when categories differ (the engine-resume case)" do
    j = Judge.make(single_shot: stub("YES"))
    assert j.(finding(), label())
  end

  test "rejects a non-match" do
    j = Judge.make(single_shot: stub("NO, these are unrelated issues."))
    refute j.(finding(), label())
  end

  test "parses the first yes/no token, case-insensitive" do
    assert Judge.make(single_shot: stub("Yes — same bug.")).(finding(), label())
    refute Judge.make(single_shot: stub("no")).(finding(), label())
  end

  test "fail-closed: an LLM error is NOT credited (never inflates recall)" do
    j = Judge.make(single_shot: fn _ -> {:error, :timeout} end)
    refute j.(finding(), label())
  end

  test "ambiguous / no yes-or-no token → NO (conservative)" do
    j = Judge.make(single_shot: stub("It depends on the threat model."))
    refute j.(finding(), label())
  end

  test "the judge prompt carries both the finding and the label substance" do
    parent = self()

    spy = fn o ->
      send(parent, {:prompt, o.user})
      {:ok, "YES"}
    end

    Judge.make(single_shot: spy).(
      finding(%{title: "UNIQUE_FINDING_TITLE"}),
      label(%{invariant: "UNIQUE_INVARIANT"})
    )

    assert_received {:prompt, p}
    assert p =~ "UNIQUE_FINDING_TITLE"
    assert p =~ "UNIQUE_INVARIANT"
  end
end
