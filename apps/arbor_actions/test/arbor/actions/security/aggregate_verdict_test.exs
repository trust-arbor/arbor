defmodule Arbor.Actions.Security.AggregateVerdictTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.{AggregateVerdict, FindingStore}
  alias Arbor.Contracts.Security.Finding

  setup do
    dir = Path.join(System.tmp_dir!(), "verify_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    finding =
      Finding.new(
        category: :dependency_risk,
        title: "git dep not pinned",
        location: %{file: "mix.exs", function: "deps/0"}
      )

    {:recorded, _} = FindingStore.record(finding, dir)
    {:ok, dir: dir, finding: finding}
  end

  test "aggregates a majority-refute verdict and annotates the finding", %{dir: dir, finding: f} do
    assert {:ok, result} =
             AggregateVerdict.run(
               %{
                 skeptic_1: "Looks intentional. VERDICT: REFUTED - mix.lock pins the SHA",
                 skeptic_2: "Can't justify it. VERDICT: REFUTED - moderate at most",
                 skeptic_3: "Real risk. VERDICT: CONFIRMED",
                 finding_id: f.id,
                 output_dir: dir
               },
               %{}
             )

    assert result.verdict == :refuted
    assert result.refuted == 2
    assert result.total == 3

    content = File.read!(Path.join(dir, f.id <> ".md"))
    assert content =~ "## Verification (adversarial)"
    assert content =~ "verdict: refuted (2/3 skeptics refuted)"
    assert content =~ "mix.lock pins the SHA"
  end

  test "a confirmed finding is annotated too (status untouched)", %{dir: dir, finding: f} do
    assert {:ok, %{verdict: :confirmed}} =
             AggregateVerdict.run(
               %{
                 skeptic_1: "VERDICT: CONFIRMED",
                 skeptic_2: "VERDICT: CONFIRMED",
                 skeptic_3: "VERDICT: CONFIRMED",
                 finding_id: f.id,
                 output_dir: dir
               },
               %{}
             )

    # status stays :open — verification is advisory
    assert FindingStore.current_status(f.id, dir) == :open
  end
end
