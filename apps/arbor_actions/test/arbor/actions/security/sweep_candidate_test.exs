# credo:disable-for-this-file
defmodule Arbor.Actions.Security.SweepCandidateTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.{SweepCandidate, SynthesizeDetector}
  alias Arbor.Contracts.Security.Finding

  # ---------------------------------------------------------------------------
  # S1 fixtures — a small tree with two fail-open authorize/2 siblings and one
  # clean function. The seed is one of the two siblings.
  # ---------------------------------------------------------------------------

  defp s1_fixture_tree do
    dir = Path.join(System.tmp_dir!(), "sweep_s1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Seed file: fail-open authorize/2.
    seed_file = Path.join(dir, "seed.ex")

    File.write!(seed_file, """
    defmodule SweepSeedFixture do
      def authorize(agent, resource) do
        do_check(agent, resource)
      rescue
        _ -> :ok
      end
    end
    """)

    # Sibling file: a DIFFERENT fail-open authorize in unreviewed code.
    sibling_file = Path.join(dir, "sibling.ex")

    File.write!(sibling_file, """
    defmodule SweepSiblingFixture do
      def authorize(token) do
        verify(token)
      rescue
        _ -> :ok
      end
    end
    """)

    # Clean file: an authorize that fails CLOSED — must NOT be flagged.
    clean_file = Path.join(dir, "clean.ex")

    File.write!(clean_file, """
    defmodule SweepCleanFixture do
      def authorize(agent) do
        do_check(agent)
      rescue
        _ -> {:error, :denied}
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, seed_file: seed_file, sibling_file: sibling_file, clean_file: clean_file}
  end

  defp s1_seed(seed_file) do
    Finding.new(
      category: :fail_open_authz,
      title: "fail-open authorize",
      location: %{file: seed_file, function: "authorize", line: 5},
      invariant_violated:
        "Authorization/verification must FAIL CLOSED — an error or unknown case must deny, never allow."
    )
  end

  defp s1_candidate(seed) do
    {:ok, result} = SynthesizeDetector.run(%{finding: seed}, %{})
    result
  end

  describe "S1 sweep" do
    test "finds the planted sibling, excludes the seed, ignores the clean function" do
      %{dir: dir, seed_file: seed_file, sibling_file: sibling_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)
      candidate = s1_candidate(seed)

      assert {:ok, result} =
               SweepCandidate.run(%{candidate: candidate, finding: seed, root: dir}, %{})

      assert result.shape == :s1
      # The candidate re-caught its own seed during the sweep (then it was excluded).
      assert result.seed_excluded == true

      files = Enum.map(result.siblings, & &1.location[:file])
      # The sibling is found...
      assert sibling_file in files
      # ...the seed is NOT a sibling (excluded by dedup_key)...
      refute seed_file in files
      # ...and the fail-CLOSED clean function is not flagged.
      assert result.hit_count == 1
      assert [sibling] = result.siblings
      assert sibling.category == :fail_open_authz
      assert sibling.location[:function] == "authorize"

      # Each S1 sibling captures the offending function's source (parseable on its
      # own) so the G4 stage pins a real positive test to the flagged sibling.
      assert is_binary(sibling.evidence[:code_excerpt])
      assert sibling.evidence[:code_excerpt] =~ "def authorize"
      assert {:ok, _} = Code.string_to_quoted(sibling.evidence[:code_excerpt])
    end

    test "dedups siblings by dedup_key" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)
      candidate = s1_candidate(seed)

      # Add a second file with the SAME class at the same function name + path-tail
      # shape is distinct here; instead assert no duplicate ids in the result.
      {:ok, result} =
        SweepCandidate.run(%{candidate: candidate, finding: seed, root: dir}, %{})

      ids = Enum.map(result.siblings, & &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "a hit at the seed's location is dropped (seed exclusion)" do
      %{dir: dir, seed_file: seed_file, sibling_file: sibling_file} = s1_fixture_tree()
      # Make the SIBLING file the "seed" so the seed exclusion drops it and the
      # original seed_file becomes the only sibling — proves exclusion is by the
      # seed's own dedup_key, not a fixed file.
      seed_at_sibling =
        Finding.new(
          category: :fail_open_authz,
          title: "fail-open authorize",
          location: %{file: sibling_file, function: "authorize"},
          invariant_violated:
            "Authorization/verification must FAIL CLOSED — an error or unknown case must deny, never allow."
        )

      candidate = s1_candidate(seed_at_sibling)

      {:ok, result} =
        SweepCandidate.run(%{candidate: candidate, finding: seed_at_sibling, root: dir}, %{})

      files = Enum.map(result.siblings, & &1.location[:file])
      assert result.seed_excluded == true
      refute sibling_file in files
      assert seed_file in files
    end

    test "record: false (default) writes nothing and returns summary: nil" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)
      candidate = s1_candidate(seed)

      {:ok, result} =
        SweepCandidate.run(%{candidate: candidate, finding: seed, root: dir}, %{})

      assert result.summary == nil
    end
  end

  # ---------------------------------------------------------------------------
  # S3 fixtures — a tree with two over-broad arbor://** grants (seed + sibling).
  # ---------------------------------------------------------------------------

  defp s3_fixture_tree do
    dir = Path.join(System.tmp_dir!(), "sweep_s3_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    seed_file = Path.join(dir, "seed.ex")

    File.write!(seed_file, """
    defmodule S3SeedFixture do
      def grant do
        "arbor://**/everything"
      end
    end
    """)

    sibling_file = Path.join(dir, "sibling.ex")

    File.write!(sibling_file, """
    defmodule S3SiblingFixture do
      def grant_admin do
        "arbor://**/admin"
      end
    end
    """)

    clean_file = Path.join(dir, "clean.ex")

    File.write!(clean_file, """
    defmodule S3CleanFixture do
      def grant_scoped do
        "arbor://fs/read/home"
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, seed_file: seed_file, sibling_file: sibling_file, clean_file: clean_file}
  end

  defp s3_seed(seed_file) do
    Finding.new(
      category: :capability_overmatch,
      title: "over-broad capability",
      location: %{file: seed_file, function: "grant"},
      invariant_violated: "Capabilities must not grant arbor://** (over-broad)."
    )
  end

  defp s3_spec do
    %{
      category: :capability_overmatch,
      invariant: "Capabilities must not grant arbor://** (over-broad).",
      match_pattern: %{kind: :literal, literal: "arbor://**"},
      name_match: ["grant"]
    }
  end

  defp s3_candidate(seed) do
    {:ok, result} = SynthesizeDetector.run(%{finding: seed, spec: s3_spec()}, %{})
    result
  end

  describe "S3 sweep via detect(root:)" do
    test "finds the planted sibling, excludes the seed, ignores the scoped grant" do
      %{dir: dir, seed_file: seed_file, sibling_file: sibling_file} = s3_fixture_tree()
      seed = s3_seed(seed_file)
      candidate = s3_candidate(seed)

      assert {:ok, result} =
               SweepCandidate.run(%{candidate: candidate, finding: seed, root: dir}, %{})

      assert result.shape == :s3
      assert result.seed_excluded == true

      files = Enum.map(result.siblings, & &1.location[:file])
      assert sibling_file in files
      refute seed_file in files
      # The scoped "arbor://fs/read/home" must NOT match the arbor://** pattern.
      assert result.hit_count == 1
      assert [sibling] = result.siblings
      assert sibling.category == :capability_overmatch
    end
  end

  describe "errors" do
    test "a candidate with no module_source → {:error, {:sweep_failed, :no_module_source}}" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)

      assert {:error, {:sweep_failed, :no_module_source}} =
               SweepCandidate.run(%{candidate: %{shape: :s1}, finding: seed, root: dir}, %{})
    end
  end
end
