# credo:disable-for-this-file
defmodule Arbor.Actions.Security.SynthesizeDetectorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.{DetectorSpec, SynthesizeDetector}
  alias Arbor.Contracts.Security.Finding

  # Write a fixture .ex file with a fail-open authorize/2 and return its path +
  # the line of the `:ok` rescue return.
  defp fail_open_fixture do
    dir = Path.join(System.tmp_dir!(), "synth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "fail_open.ex")

    # The `_ -> :ok` is on line 5 (1=defmodule, 2=def, 3=body, 4=rescue, 5=clause).
    File.write!(file, """
    defmodule FailOpenFixture do
      def authorize(agent, resource) do
        do_check(agent, resource)
      rescue
        _ -> :ok
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    {file, 5}
  end

  defp finding(file, line, overrides \\ %{}) do
    Finding.new(
      Keyword.merge(
        [
          category: :fail_open_authz,
          title: "fail-open authorize",
          location: %{file: file, function: "authorize", line: line},
          invariant_violated: "Authorization must fail closed."
        ],
        Map.to_list(overrides)
      )
    )
  end

  describe "G1 positive — deterministic spec re-catches its own seed" do
    test "returns a candidate whose G1 passes" do
      {file, line} = fail_open_fixture()
      f = finding(file, line)

      assert {:ok, result} = SynthesizeDetector.run(%{finding: f}, %{})
      assert result.g1 == :passed
      assert result.category == :fail_open_authz
      assert is_binary(result.module_source)
      assert result.spec.category == :fail_open_authz
    end

    test "the candidate module compiles and flags the seed at its function" do
      {file, line} = fail_open_fixture()
      f = finding(file, line)

      {:ok, result} = SynthesizeDetector.run(%{finding: f}, %{})

      # The G1-validated source must itself compile and re-catch.
      name = "Arbor.Eval.Checks.Synthesized.PostTest_#{System.unique_integer([:positive])}"

      [{mod, _} | _] =
        Code.compile_string(String.replace(result.module_source, result.module_name, name))

      ast =
        quote do
          def authorize(a, b) do
            do_check(a, b)
          rescue
            _ -> :ok
          end
        end

      assert [v] = mod.run(%{ast: ast}).violations
      assert v.function == "authorize"
    end
  end

  describe "G1 negative — a spec that does NOT match the seed is rejected" do
    test "non-matching name_match → {:error, {:g1_failed, _}}" do
      {file, line} = fail_open_fixture()
      f = finding(file, line)

      # A spec whose name_match cannot match `authorize` → detector flags nothing
      # in the seed → G1 must fail.
      bad_spec = %{
        category: :fail_open_authz,
        invariant: "Authorization must fail closed.",
        name_match: ["this_matches_no_function"],
        target_literals: [:ok, true, {:ok, :_}],
        clause_position: :rescue_or_catch_all
      }

      assert {:error, {:g1_failed, reason}} =
               SynthesizeDetector.run(%{finding: f, spec: bad_spec}, %{})

      assert reason == :no_violation_recaught
    end

    test "wrong target_literals (seed returns :ok, spec flags only true) → g1_failed" do
      {file, line} = fail_open_fixture()
      f = finding(file, line)

      bad_spec = %{
        category: :fail_open_authz,
        invariant: "Authorization must fail closed.",
        name_match: ["authoriz"],
        # seed rescues to :ok, but this only flags `true`
        target_literals: [true],
        clause_position: :rescue_or_catch_all
      }

      assert {:error, {:g1_failed, :no_violation_recaught}} =
               SynthesizeDetector.run(%{finding: f, spec: bad_spec}, %{})
    end

    test "matching name but wrong function location → g1_failed wrong_location" do
      {file, _line} = fail_open_fixture()
      # Finding claims the bug is in a different function than the detector finds.
      f = finding(file, 5, %{location: %{file: file, function: "some_other_fn", line: 99}})

      assert {:error, {:g1_failed, {:wrong_location, "some_other_fn", 99}}} =
               SynthesizeDetector.run(%{finding: f}, %{})
    end
  end

  describe "scope boundary + spec sources" do
    test "a non-S1 category is rejected with {:unsupported_shape, _}" do
      {file, line} = fail_open_fixture()
      f = finding(file, line, %{category: :crypto_weakness})

      assert {:error, {:unsupported_shape, :crypto_weakness}} =
               SynthesizeDetector.run(%{finding: f}, %{})
    end

    test "accepts an LLM-produced JSON spec and G1-validates it" do
      {file, line} = fail_open_fixture()
      f = finding(file, line)

      json =
        Jason.encode!(%{
          "name" => "llm_authz",
          "category" => "fail_open_authz",
          "invariant" => "Authorization must fail closed.",
          "name_match" => ["authoriz", "@can?"],
          "target_literals" => ["ok", "true", ["ok", "_"]],
          "exclusions" => [["ok", "verified"]],
          "clause_position" => "rescue_or_catch_all"
        })

      assert {:ok, %{g1: :passed} = result} =
               SynthesizeDetector.run(%{finding: f, spec: json}, %{})

      assert result.spec.name == "llm_authz"
    end

    test "a blank LLM spec falls back to the deterministic spec" do
      {file, line} = fail_open_fixture()
      f = finding(file, line)

      assert {:ok, %{g1: :passed}} = SynthesizeDetector.run(%{finding: f, spec: ""}, %{})
    end

    test "an unreadable seed file → {:error, {:seed_unreadable, _}}" do
      f = finding("/nonexistent/path/nope.ex", 5)

      assert {:error, {:seed_unreadable, _}} = SynthesizeDetector.run(%{finding: f}, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # E1.2 — S3 (tree-wide pattern) synthesis + G1
  # ---------------------------------------------------------------------------

  # A seed file whose `grant/0` returns an over-broad `arbor://**` capability —
  # the tree-wide-pattern shape of :capability_overmatch.
  defp overmatch_fixture do
    dir = Path.join(System.tmp_dir!(), "synth_s3_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "overmatch.ex")

    File.write!(file, """
    defmodule OvermatchFixture do
      def grant do
        "arbor://**/everything"
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    file
  end

  defp s3_finding(file, overrides \\ %{}) do
    Finding.new(
      Keyword.merge(
        [
          category: :capability_overmatch,
          title: "over-broad capability",
          location: %{file: file, function: "grant"},
          invariant_violated: "Capabilities must not grant arbor://** (over-broad)."
        ],
        Map.to_list(overrides)
      )
    )
  end

  defp s3_spec(overrides \\ %{}) do
    Map.merge(
      %{
        category: :capability_overmatch,
        invariant: "Capabilities must not grant arbor://** (over-broad).",
        match_pattern: %{kind: :literal, literal: "arbor://**"},
        name_match: ["grant"]
      },
      overrides
    )
  end

  describe "S3 G1 positive — tree-wide pattern re-catches its own seed" do
    test "an S3 spec whose pattern matches the seed passes G1" do
      file = overmatch_fixture()
      f = s3_finding(file)

      assert {:ok, result} = SynthesizeDetector.run(%{finding: f, spec: s3_spec()}, %{})
      assert result.g1 == :passed
      assert result.shape == :s3
      assert result.category == :capability_overmatch
      assert is_binary(result.module_source)
    end

    test "the candidate S3 module compiles + re-catches via detect/1" do
      file = overmatch_fixture()
      f = s3_finding(file)

      {:ok, result} = SynthesizeDetector.run(%{finding: f, spec: s3_spec()}, %{})

      name =
        "Arbor.Actions.Security.Detectors.Synthesized.PostS3_#{System.unique_integer([:positive])}"

      [{mod, _} | _] =
        Code.compile_string(String.replace(result.module_source, result.module_name, name))

      findings = mod.detect(root: Path.dirname(file))
      assert [found] = findings
      assert found.location[:function] == "grant"
    end

    test "accepts an LLM-produced JSON S3 spec and G1-validates it" do
      file = overmatch_fixture()
      f = s3_finding(file)

      json =
        Jason.encode!(%{
          "shape" => "s3",
          "category" => "capability_overmatch",
          "invariant" => "Capabilities must not grant arbor://** (over-broad).",
          "match_pattern" => %{"kind" => "literal", "literal" => "arbor://**"},
          "name_match" => ["grant"]
        })

      assert {:ok, %{g1: :passed, shape: :s3}} =
               SynthesizeDetector.run(%{finding: f, spec: json}, %{})
    end

    # Regression: a pre-built %DetectorSpec{} struct is the natural programmatic
    # spec source (e.g. DetectorSynthesisLoop forwarding opts[:spec], or any caller
    # that built the spec itself). Before the resolve_spec/2 clause reordering, a
    # struct fell into the generic `is_map/1` clause and was passed to
    # DetectorSpec.build/1, which does Access (`params[:category]`) on the struct
    # and RAISED — the dedicated %DetectorSpec{} clause was dead code shadowed by
    # is_map/1. This test passes a built struct (S3 and S1) and asserts G1 passes;
    # it fails (raises) on the pre-fix clause ordering.
    test "accepts a pre-built %DetectorSpec{} struct (S3 + S1) and G1-validates it" do
      s3_file = overmatch_fixture()
      {:ok, built_s3} = DetectorSpec.build(s3_spec())

      assert {:ok, %{g1: :passed, shape: :s3}} =
               SynthesizeDetector.run(%{finding: s3_finding(s3_file), spec: built_s3}, %{})

      {s1_file, s1_line} = fail_open_fixture()

      {:ok, built_s1} =
        DetectorSpec.build(%{
          shape: :s1,
          category: :fail_open_authz,
          invariant: "Authorization must fail closed.",
          name_match: ["authoriz"],
          target_literals: [:ok],
          clause_position: :rescue_or_catch_all
        })

      assert {:ok, %{g1: :passed, shape: :s1}} =
               SynthesizeDetector.run(%{finding: finding(s1_file, s1_line), spec: built_s1}, %{})
    end
  end

  describe "S3 G1 negative — a pattern that does NOT match is rejected" do
    test "a non-matching literal → {:error, {:g1_failed, :no_violation_recaught}}" do
      file = overmatch_fixture()
      f = s3_finding(file)

      bad = s3_spec(%{match_pattern: %{kind: :literal, literal: "arbor://never/matches/this"}})

      assert {:error, {:g1_failed, :no_violation_recaught}} =
               SynthesizeDetector.run(%{finding: f, spec: bad}, %{})
    end

    test "matches the pattern but in a different function than the finding → wrong_location" do
      file = overmatch_fixture()
      # Finding claims a different function; the detector flags `grant`.
      f = s3_finding(file, %{location: %{file: file, function: "some_other_fn"}})

      assert {:error, {:g1_failed, {:wrong_location, _file, "some_other_fn"}}} =
               SynthesizeDetector.run(%{finding: f, spec: s3_spec()}, %{})
    end
  end

  describe "S3 scope boundary" do
    test "an S3 category with no supplied spec → {:no_deterministic_spec, _}" do
      file = overmatch_fixture()
      f = s3_finding(file)

      # No deterministic template exists for S3 categories (the match_pattern is
      # finding-specific), so the LLM/spec path must supply it.
      assert {:error, {:no_deterministic_spec, :capability_overmatch}} =
               SynthesizeDetector.run(%{finding: f}, %{})
    end

    test "a bespoke-correlation category is rejected as :unsupported_shape" do
      file = overmatch_fixture()
      # :crypto_weakness (SignedFieldCoverage's transitive-closure shape) is NOT a
      # tree-wide pattern → not synthesizable, even with a match_pattern supplied.
      f = s3_finding(file, %{category: :crypto_weakness})

      assert {:error, {:unsupported_shape, :crypto_weakness}} =
               SynthesizeDetector.run(
                 %{finding: f, spec: s3_spec(%{category: :crypto_weakness})},
                 %{}
               )
    end
  end
end
