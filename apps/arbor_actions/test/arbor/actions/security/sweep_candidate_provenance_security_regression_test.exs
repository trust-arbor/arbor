# credo:disable-for-this-file
defmodule Arbor.Actions.Security.SweepCandidateProvenanceSecurityRegressionTest do
  @moduledoc """
  Security regression for F-008 (2026-10-11 cross-library review, High):
  `SweepCandidate` used to `Code.compile_string` `candidate.module_source`
  verbatim — a map any agent-authored DOT graph can put in the context — and
  then run its `detect/1` / `run/1`. Module-body code executed at compile time;
  the detector entry points executed right after. The fix rebuilds the detector
  from the candidate's validated `spec` through `DetectorTemplate` and refuses a
  `module_source` that differs from that regeneration.

  Every refusal test plants `send(self(), ...)` at BOTH the module-body
  (compile-time) and detector-run positions: `Code.compile_string/1` evaluates
  the module body in the calling process, so a received message is direct proof
  that the caller's text was compiled or run. These tests fail on the pre-fix
  SweepCandidate (the payload compiles and runs, the sweep returns `{:ok, _}`)
  and pass after.
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  alias Arbor.Actions.Security.{DetectorSpec, SweepCandidate, SynthesizeDetector}
  alias Arbor.Contracts.Security.Finding

  @invariant "Authorization/verification must FAIL CLOSED — an error or unknown case must deny, never allow."

  # A detector-shaped module whose body AND both entry points phone home. If
  # SweepCandidate ever compiles caller text again, the test process receives
  # :pwned_at_compile (module body runs at compile time) and, for S3 shape,
  # :pwned_at_run (detect/1 is invoked by the sweep).
  @payload """
  defmodule Arbor.Actions.Security.Sweep.PwnedCandidate do
    send(self(), :pwned_at_compile)

    def category, do: :fail_open_authz

    def detect(_opts) do
      send(self(), :pwned_at_run)
      []
    end

    def run(_ctx) do
      send(self(), :pwned_at_run)
      %{passed: true, violations: [], suggestions: []}
    end
  end
  """

  # ---------------------------------------------------------------------------
  # Fixtures — the same small trees sweep_candidate_test.exs uses.
  # ---------------------------------------------------------------------------

  defp s1_fixture_tree do
    dir = Path.join(System.tmp_dir!(), "sweep_prov_s1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    seed_file = Path.join(dir, "seed.ex")

    File.write!(seed_file, """
    defmodule SweepProvSeedFixture do
      def authorize(agent, resource) do
        do_check(agent, resource)
      rescue
        _ -> :ok
      end
    end
    """)

    sibling_file = Path.join(dir, "sibling.ex")

    File.write!(sibling_file, """
    defmodule SweepProvSiblingFixture do
      def authorize(token) do
        verify(token)
      rescue
        _ -> :ok
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, seed_file: seed_file, sibling_file: sibling_file}
  end

  defp s1_seed(seed_file) do
    Finding.new(
      category: :fail_open_authz,
      title: "fail-open authorize",
      location: %{file: seed_file, function: "authorize", line: 5},
      invariant_violated: @invariant
    )
  end

  defp s3_fixture_tree do
    dir = Path.join(System.tmp_dir!(), "sweep_prov_s3_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    seed_file = Path.join(dir, "seed.ex")

    File.write!(seed_file, """
    defmodule S3ProvSeedFixture do
      def grant do
        "arbor://**/everything"
      end
    end
    """)

    sibling_file = Path.join(dir, "sibling.ex")

    File.write!(sibling_file, """
    defmodule S3ProvSiblingFixture do
      def grant_admin do
        "arbor://**/admin"
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, seed_file: seed_file, sibling_file: sibling_file}
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

  defp run_sweep(candidate, seed, dir) do
    SweepCandidate.run(%{candidate: candidate, finding: seed, root: dir}, %{})
  end

  defp refute_payload_ran do
    refute_received :pwned_at_compile
    refute_received :pwned_at_run
  end

  # ---------------------------------------------------------------------------
  # 1. module_source with a bogus/absent spec is refused outright
  # ---------------------------------------------------------------------------

  describe "security regression (F-008): caller-supplied module_source is never compiled" do
    test "a candidate with module_source but NO spec is refused and the payload never runs" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)

      # Whatever the candidate claims its shape is (S3 runs detect/1 straight
      # away; S1 runs run/1 per file), with no spec there is nothing trustworthy
      # to regenerate from — fail closed.
      for shape <- [:s3, "s3", :s1, nil] do
        assert {:error, {:sweep_failed, :invalid_spec}} =
                 run_sweep(%{shape: shape, module_source: @payload}, seed, dir)
      end

      # String-keyed (DOT/JSON path) form of the same attack.
      assert {:error, {:sweep_failed, :invalid_spec}} =
               run_sweep(%{"shape" => "s3", "module_source" => @payload}, seed, dir)

      refute_payload_ran()
    end

    test "a candidate whose spec does not coerce to a valid DetectorSpec is refused" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)

      bogus_specs = [
        # S1 category but no name_match / target_literals → build/1 rejects
        %{"category" => "fail_open_authz", "invariant" => "x"},
        # bespoke-correlation category: not a synthesizable shape
        %{category: :crypto_weakness, invariant: "x", name_match: ["a"], target_literals: [:ok]},
        # S3 category with no match_pattern
        %{"shape" => "s3", "category" => "capability_overmatch", "invariant" => "x"},
        # unknown category token (allowlist miss → never minted)
        %{
          "category" => "totally_new_category",
          "name_match" => ["a"],
          "target_literals" => ["ok"]
        },
        # not even a map
        "not a spec",
        %{},
        []
      ]

      for spec <- bogus_specs do
        assert {:error, {:sweep_failed, :invalid_spec}} =
                 run_sweep(%{shape: :s3, spec: spec, module_source: @payload}, seed, dir),
               "expected refusal for spec #{inspect(spec)}"
      end

      refute_payload_ran()
    end
  end

  # ---------------------------------------------------------------------------
  # 2. a valid spec does not launder a foreign module_source
  # ---------------------------------------------------------------------------

  describe "security regression (F-008): module_source must be the template output for THIS spec" do
    test "one injected line into a genuine candidate's source is a provenance mismatch" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)
      {:ok, candidate} = SynthesizeDetector.run(%{finding: seed}, %{})

      header = "defmodule #{candidate.module_name} do"
      assert String.starts_with?(candidate.module_source, header)

      tampered =
        String.replace(
          candidate.module_source,
          header,
          header <> "\n  send(self(), :pwned_at_compile)",
          global: false
        )

      assert tampered != candidate.module_source

      assert {:error, {:sweep_failed, :module_source_provenance_mismatch}} =
               run_sweep(%{candidate | module_source: tampered}, seed, dir)

      refute_payload_ran()
    end

    test "a wholly foreign module_source next to a valid spec is refused before any compile" do
      %{dir: dir, seed_file: seed_file} = s3_fixture_tree()
      seed = s3_seed(seed_file)
      {:ok, candidate} = SynthesizeDetector.run(%{finding: seed, spec: s3_spec()}, %{})

      # S3 shape → the old code would have called detect/1 immediately.
      assert {:error, {:sweep_failed, :module_source_provenance_mismatch}} =
               run_sweep(%{candidate | module_source: @payload}, seed, dir)

      # And the string-keyed form, as a DOT/JSON-fed candidate would arrive.
      assert {:error, {:sweep_failed, :module_source_provenance_mismatch}} =
               run_sweep(
                 %{
                   "shape" => "s3",
                   "spec" => Map.from_struct(candidate.spec),
                   "module_source" => @payload
                 },
                 seed,
                 dir
               )

      refute_payload_ran()
    end

    test "the source of a DIFFERENT genuine candidate is a mismatch (the binding is to this spec)" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)

      {:ok, deterministic} = SynthesizeDetector.run(%{finding: seed}, %{})

      narrower = %{
        name: "narrower_authz",
        category: :fail_open_authz,
        invariant: @invariant,
        name_match: ["authoriz"],
        target_literals: [:ok],
        clause_position: :rescue
      }

      {:ok, other} = SynthesizeDetector.run(%{finding: seed, spec: narrower}, %{})
      assert other.module_source != deterministic.module_source

      # Both sources are genuine template output — but not for THIS spec.
      assert {:error, {:sweep_failed, :module_source_provenance_mismatch}} =
               run_sweep(%{deterministic | module_source: other.module_source}, seed, dir)

      assert {:error, {:sweep_failed, :module_source_provenance_mismatch}} =
               run_sweep(%{other | module_source: deterministic.module_source}, seed, dir)
    end

    test "a non-string module_source is a provenance mismatch, not a crash" do
      %{dir: dir, seed_file: seed_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)
      {:ok, candidate} = SynthesizeDetector.run(%{finding: seed}, %{})

      for bad <- [[], %{}, 42, [@payload]] do
        assert {:error, {:sweep_failed, :module_source_provenance_mismatch}} =
                 run_sweep(%{candidate | module_source: bad}, seed, dir)
      end

      refute_payload_ran()
    end
  end

  # ---------------------------------------------------------------------------
  # 3. positive control — genuine SynthesizeDetector candidates still sweep
  # ---------------------------------------------------------------------------

  describe "positive control: a genuine SynthesizeDetector candidate still sweeps" do
    test "an S1 candidate (struct spec + its template module_source) finds the sibling" do
      %{dir: dir, seed_file: seed_file, sibling_file: sibling_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)
      {:ok, candidate} = SynthesizeDetector.run(%{finding: seed}, %{})

      assert {:ok, result} = run_sweep(candidate, seed, dir)
      assert result.shape == :s1
      assert result.seed_excluded == true
      assert [sibling] = result.siblings
      assert sibling.location[:file] == sibling_file
      assert sibling.category == :fail_open_authz
    end

    test "an S3 candidate finds the sibling via detect/1" do
      %{dir: dir, seed_file: seed_file, sibling_file: sibling_file} = s3_fixture_tree()
      seed = s3_seed(seed_file)
      {:ok, candidate} = SynthesizeDetector.run(%{finding: seed, spec: s3_spec()}, %{})

      assert {:ok, result} = run_sweep(candidate, seed, dir)
      assert result.shape == :s3
      assert result.seed_excluded == true
      assert [sibling] = result.siblings
      assert sibling.location[:file] == sibling_file
    end

    test "a JSON-clean (string-keyed) S3 candidate, as it crosses the Engine context, still sweeps" do
      %{dir: dir, seed_file: seed_file, sibling_file: sibling_file} = s3_fixture_tree()
      seed = s3_seed(seed_file)
      {:ok, candidate} = SynthesizeDetector.run(%{finding: seed, spec: s3_spec()}, %{})
      spec = candidate.spec

      json_clean = %{
        "shape" => "s3",
        "module_name" => candidate.module_name,
        "module_source" => candidate.module_source,
        "spec" => %{
          "shape" => "s3",
          "name" => spec.name,
          "category" => Atom.to_string(spec.category),
          "invariant" => spec.invariant,
          "name_match" => spec.name_match,
          "exclusions" => [],
          "match_pattern" => %{"kind" => "literal", "literal" => "arbor://**"}
        }
      }

      # It really is JSON-clean (survives an encode/decode round trip unchanged).
      assert json_clean == json_clean |> Jason.encode!() |> Jason.decode!()

      assert {:ok, result} = run_sweep(json_clean, seed, dir)
      assert result.shape == :s3
      assert [sibling] = result.siblings
      assert sibling.location[:file] == sibling_file
    end

    test "a JSON-clean S1 candidate with tuple/atom literals in token form still sweeps" do
      %{dir: dir, seed_file: seed_file, sibling_file: sibling_file} = s1_fixture_tree()
      seed = s1_seed(seed_file)

      spec_params = %{
        name: "llm_authz",
        category: :fail_open_authz,
        invariant: @invariant,
        name_match: ["authoriz"],
        target_literals: [:ok, {:ok, :_}],
        exclusions: [{:ok, :verified}],
        clause_position: :rescue_or_catch_all
      }

      {:ok, candidate} = SynthesizeDetector.run(%{finding: seed, spec: spec_params}, %{})

      json_clean = %{
        "shape" => "s1",
        "module_source" => candidate.module_source,
        "spec" => %{
          "shape" => "s1",
          "name" => "llm_authz",
          "category" => "fail_open_authz",
          "invariant" => @invariant,
          "name_match" => ["authoriz"],
          "target_literals" => ["ok", ["ok", "_"]],
          "exclusions" => [["ok", "verified"]],
          "clause_position" => "rescue_or_catch_all"
        }
      }

      assert json_clean == json_clean |> Jason.encode!() |> Jason.decode!()
      assert {:ok, %DetectorSpec{}} = DetectorSpec.coerce(json_clean["spec"])

      assert {:ok, result} = run_sweep(json_clean, seed, dir)
      assert result.shape == :s1
      assert result.seed_excluded == true
      assert [sibling] = result.siblings
      assert sibling.location[:file] == sibling_file
    end
  end
end
