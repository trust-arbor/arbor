# credo:disable-for-this-file
defmodule Arbor.Actions.Security.DetectorSynthesisLoopTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  alias Arbor.Actions.Security.{DetectorProposal, DetectorSynthesisLoop}
  alias Arbor.Contracts.Security.Finding

  # A fixture tree: the seed file (fail-open authorize) + two SIBLING files with
  # the same fail-open authz class, so the sweep finds siblings to triage.
  defp fixture_tree do
    dir = Path.join(System.tmp_dir!(), "synloop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    seed = Path.join(dir, "seed.ex")

    File.write!(seed, """
    defmodule SeedAuthz do
      def authorize(agent, resource) do
        do_check(agent, resource)
      rescue
        _ -> :ok
      end
    end
    """)

    # Two siblings: same fail-open authz shape, different functions.
    File.write!(Path.join(dir, "sibling_a.ex"), """
    defmodule SiblingA do
      def authorize_request(ctx) do
        run_chain(ctx)
      rescue
        _ -> {:ok, :authorized}
      end
    end
    """)

    File.write!(Path.join(dir, "sibling_b.ex"), """
    defmodule SiblingB do
      def verify_token(tok) do
        check(tok)
      rescue
        _ -> true
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    {dir, seed}
  end

  defp seed_finding(file) do
    Finding.new(
      category: :fail_open_authz,
      title: "fail-open authorize",
      location: %{file: file, function: "authorize", line: 5},
      invariant_violated: "Authorization must fail closed."
    )
  end

  describe "happy path — admitted proposal" do
    test "high-confidence verdicts → {:ok, proposal} with compilable sources" do
      {dir, seed} = fixture_tree()
      finding = seed_finding(seed)

      # First sweep to learn the sibling ids, then build all-confirmed verdicts.
      {:ok, sweep} =
        Arbor.Actions.Security.SweepCandidate.run(
          %{
            candidate:
              elem(Arbor.Actions.Security.SynthesizeDetector.run(%{finding: finding}, %{}), 1),
            finding: finding,
            root: dir,
            record: false
          },
          %{}
        )

      assert sweep.siblings != [], "fixture should produce at least one sibling"
      verdicts = Map.new(sweep.siblings, fn s -> {s.id, :confirmed} end)

      assert {:ok, %DetectorProposal{} = proposal} =
               DetectorSynthesisLoop.propose(finding, verdicts, root: dir)

      assert proposal.shape == :s1
      assert proposal.admit? == true
      assert proposal.precision.admit? == true
      assert proposal.precision.precision == 1.0
      # Same sibling set (compare by stable id; timestamps differ across sweeps).
      assert Enum.map(proposal.siblings, & &1.id) |> Enum.sort() ==
               Enum.map(sweep.siblings, & &1.id) |> Enum.sort()

      # all confirmed → no FP hits
      assert proposal.fp_hits == []

      # target_path / registration_edits are correct for S1.
      assert proposal.target_path ==
               "apps/arbor_common/lib/arbor/eval/checks/synthesized_fail_open_authz.ex"

      assert [%{kind: :append_to_suite_evals}, %{kind: :add_static_scan_mappings}] =
               proposal.registration_edits

      assert proposal.test_path ==
               "apps/arbor_common/test/arbor/eval/checks/synthesized_fail_open_authz_test.exs"

      # module_source compiles.
      mod_name = "Arbor.Eval.Checks.Synthesized.LoopChk_#{System.unique_integer([:positive])}"

      assert [{_, _} | _] =
               Code.compile_string(
                 String.replace(proposal.module_source, proposal.module_name, mod_name)
               )

      # test_source compiles.
      tname = "Arbor.Eval.Checks.Synthesized.LoopTest_#{System.unique_integer([:positive])}"
      assert [{_, _} | _] = Code.compile_string(rename_test_module(proposal.test_source, tname))
    end

    test "mixed verdicts above floor → admitted, FP hits captured" do
      {dir, seed} = fixture_tree()
      finding = seed_finding(seed)

      {:ok, sweep} =
        Arbor.Actions.Security.SweepCandidate.run(
          %{
            candidate:
              elem(Arbor.Actions.Security.SynthesizeDetector.run(%{finding: finding}, %{}), 1),
            finding: finding,
            root: dir,
            record: false
          },
          %{}
        )

      # Need at least 2 siblings for a meaningful mix; if only 1, confirm it.
      [first | rest] = sweep.siblings

      verdicts =
        case rest do
          [second | _] -> %{first.id => :confirmed, second.id => :refuted}
          [] -> %{first.id => :confirmed}
        end

      result = DetectorSynthesisLoop.propose(finding, verdicts, root: dir, threshold: 0.5)

      case result do
        {:ok, proposal} ->
          assert proposal.precision.precision >= 0.5
          assert proposal.admit?

        {:flagged, reason} ->
          flunk("expected admit, got flagged: #{inspect(reason)}")
      end
    end
  end

  describe "flagged path — below precision floor" do
    test "mostly-refuted verdicts → {:flagged, {:below_precision_floor, _, _}}, no proposal" do
      {dir, seed} = fixture_tree()
      finding = seed_finding(seed)

      {:ok, sweep} =
        Arbor.Actions.Security.SweepCandidate.run(
          %{
            candidate:
              elem(Arbor.Actions.Security.SynthesizeDetector.run(%{finding: finding}, %{}), 1),
            finding: finding,
            root: dir,
            record: false
          },
          %{}
        )

      # All refuted → precision 0.0 < floor.
      verdicts = Map.new(sweep.siblings, fn s -> {s.id, :refuted} end)

      assert {:flagged, {:below_precision_floor, precision, threshold}} =
               DetectorSynthesisLoop.propose(finding, verdicts, root: dir, threshold: 0.5)

      assert precision == 0.0
      assert threshold == 0.5
    end

    test "no triaged siblings → {:flagged, :no_triaged_siblings}" do
      {dir, seed} = fixture_tree()
      finding = seed_finding(seed)

      assert {:flagged, :no_triaged_siblings} =
               DetectorSynthesisLoop.propose(finding, %{}, root: dir)
    end
  end

  describe "error path" do
    test "an unsupported category propagates {:error, {:synthesis_failed, _}}" do
      {_dir, seed} = fixture_tree()

      finding =
        Finding.new(
          category: :crypto_weakness,
          title: "crypto",
          location: %{file: seed, function: "authorize"},
          invariant_violated: "x"
        )

      assert {:error, {:synthesis_failed, {:unsupported_shape, :crypto_weakness}}} =
               DetectorSynthesisLoop.propose(finding, %{})
    end
  end

  defp rename_test_module(source, new_name) do
    Regex.replace(~r/\Adefmodule\s+[A-Za-z0-9_.]+\s+do/m, source, "defmodule #{new_name} do",
      global: false
    )
  end
end
