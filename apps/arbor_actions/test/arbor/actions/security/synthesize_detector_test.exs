# credo:disable-for-this-file
defmodule Arbor.Actions.Security.SynthesizeDetectorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.SynthesizeDetector
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
end
