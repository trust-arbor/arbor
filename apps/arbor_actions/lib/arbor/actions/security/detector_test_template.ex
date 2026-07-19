defmodule Arbor.Actions.Security.DetectorTestTemplate do
  @moduledoc """
  Emits **compilable ExUnit source** for a synthesized security detector — the
  Security Sentinel's **G4** stage (E1.4): a generated FP-regression test file.

  A synthesized detector (`DetectorTemplate`) is only valuable as a *permanent*
  net if its coverage is pinned by tests. G4 generates that test file from the
  same data the detector was born from:

    * a **POSITIVE** test — the detector flags a confirmed sibling (proves it
      catches the class), and
    * an **FP-REGRESSION** test per refuted hit — the detector does NOT flag a
      site the adversarial verifier refuted (pins the tightening in place so a
      future refactor can't re-broaden the predicate silently).

  The two idioms mirror the EXISTING detector tests exactly:

    * **S1** (per-file AST) — `Arbor.Eval.Checks.AuthorizationSmellsTest`'s shape:
      build the offending AST and assert on `run(%{ast: ast}).violations`.
    * **S3** (whole-tree) — `…SignedFieldCoverageTest`'s shape: write the
      offending source into a tmp dir and assert on `detect(root: dir)`.

  ## Injection-safety (MANDATORY)

  The generated file is **compiled by the suite**, and every code excerpt
  originates from scanned — possibly adversarial — repo code. A naive template
  that raw-interpolated an excerpt into the generated source would execute an
  attacker's `\#{System.cmd(...)}` at *compile time* of the generated test.

  This module NEVER raw-interpolates an excerpt. Every excerpt and literal
  reaches the generated source through `inspect/1` (which escapes `\#{}`, quotes,
  and newlines into an inert string literal). The generated test then *parses*
  that string literal at its own runtime — `Code.string_to_quoted!/1` for S1,
  `File.write!/2` for S3 — so the excerpt is data, never a heredoc body or an
  interpolation hole. The module/detector names and invariant text reach the
  source the same way (`inspect/1`), and the one human-readable `@moduledoc`
  interpolation is run through the hardened `escape_doc/1` (neutralizing `\#{}`,
  `\"\"\"`, and quotes).

  The accompanying `…DetectorTestTemplateTest` includes a G4 injection-regression
  test: an excerpt carrying a `\#{File.write!(sentinel, …)}` payload must NOT
  execute the payload when the generated source is compiled. (It FAILS without
  the `inspect/1` hardening — the payload would run at compile time.)
  """

  alias Arbor.Actions.Security.DetectorSpec

  @doc """
  Returns compilable ExUnit source for a generated FP-regression test of the
  synthesized detector described by `spec`.

  Arguments:

    * `spec` — the `DetectorSpec` the detector was synthesized from (its `shape`
      selects the test idiom: S1 = AST/`quote`-equivalent, S3 = tmp-dir/`detect`).
    * `module_name` — the name the detector module is compiled under in the
      supplied `module_source` (the generated test rewrites it to a private name
      and compiles that source itself, so the test is self-contained).
    * `confirmed_siblings` — the confirmed `Finding`s (or maps); the FIRST with a
      usable code excerpt seeds the POSITIVE test. Each Finding's
      `evidence.code_excerpt` is the offending code.
    * `fp_hits` — the refuted `Finding`s (or maps); each with a usable excerpt
      seeds one FP-regression test asserting the detector stays quiet.

  Options:

    * `:module_source` — the detector module source (from `DetectorTemplate`);
      the generated test compiles it in-memory. REQUIRED in practice.
    * `:test_module` — the generated test module name (default derived from spec).
    * `:detector_compile_name` — the name the embedded detector source is
      compiled under inside the test (default a synthesized-test namespace).

  When neither a confirmed sibling nor the seed carries a usable excerpt, the
  POSITIVE test falls back to the spec-derived canonical offending shape (so the
  generated test always has at least one positive assertion).
  """
  @spec generate(DetectorSpec.t(), String.t(), [map()], [map()], keyword()) :: String.t()
  def generate(%DetectorSpec{} = spec, module_name, confirmed_siblings, fp_hits, opts \\ [])
      when is_binary(module_name) and is_list(confirmed_siblings) and is_list(fp_hits) do
    test_module = opts[:test_module] || default_test_module(spec)
    detector_name = opts[:detector_compile_name] || default_detector_compile_name(spec)
    detector_source = opts[:module_source] || ""

    positive = positive_excerpt(spec, confirmed_siblings)
    fps = fp_hits |> Enum.map(&excerpt_of/1) |> Enum.reject(&is_nil/1)

    case spec.shape do
      :s3 ->
        s3_source(spec, module_name, detector_source, test_module, detector_name, positive, fps)

      _ ->
        s1_source(spec, module_name, detector_source, test_module, detector_name, positive, fps)
    end
  end

  # ---------------------------------------------------------------------------
  # S1 test source (the AuthorizationSmellsTest idiom: build AST + assert run/1)
  # ---------------------------------------------------------------------------

  defp s1_source(spec, module_name, detector_source, test_module, detector_name, positive, fps) do
    """
    # credo:disable-for-this-file
    defmodule #{test_module} do
      @moduledoc \"\"\"
      SYNTHESIZED G4 FP-regression test (Security Sentinel E1.4).

      Pins the synthesized S1 detector enforcing: #{escape_doc(spec.invariant)}

      The detector source is compiled in-memory so this test is self-contained.
      Every offending code excerpt is embedded as an INERT STRING LITERAL (via
      inspect/1) and parsed at runtime — never raw-interpolated — so an
      adversarial interpolation payload in a scanned excerpt cannot execute when
      this file is compiled.
      \"\"\"
      use ExUnit.Case, async: true

      @moduletag :fast
      @moduletag :security

      # Compile the synthesized detector under a private name so this test is
      # self-contained (it does not depend on the detector being registered).
      @detector_source #{safe_literal(detector_source)}
      @detector_module #{safe_literal(detector_name)}

      setup_all do
        [{mod, _bin} | _] =
          Code.compile_string(
            String.replace(@detector_source, #{safe_literal(module_name)}, @detector_module)
          )

        {:ok, detector: mod}
      end

      # The excerpts are inert string literals; parsed (not interpolated) here.
      defp violation_types(detector, code) do
        ast = Code.string_to_quoted!(code)
        detector.run(%{ast: ast}).violations |> Enum.map(& &1.type)
      end

      describe "positive — flags a confirmed sibling of the class" do
        test "the detector flags the confirmed offending code", %{detector: detector} do
          code = #{safe_literal(positive)}

          assert violation_types(detector, code) != [],
                 "synthesized detector failed to flag a confirmed sibling"
        end
      end
    #{s1_fp_tests(fps)}end
    """
  end

  defp s1_fp_tests([]), do: ""

  defp s1_fp_tests(fps) do
    body =
      fps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {excerpt, i} ->
        """
            test "FP-regression #{i}: does NOT flag a refuted excerpt", %{detector: detector} do
              code = #{safe_literal(excerpt)}

              assert violation_types(detector, code) == [],
                     "synthesized detector regressed: re-flagged a refuted false positive"
            end
        """
      end)

    """
      describe "FP-regression — stays quiet on refuted false positives" do
    #{body}  end
    """
  end

  # ---------------------------------------------------------------------------
  # S3 test source (the SignedFieldCoverageTest idiom: tmp-dir files + detect/1)
  # ---------------------------------------------------------------------------

  defp s3_source(spec, module_name, detector_source, test_module, detector_name, positive, fps) do
    """
    # credo:disable-for-this-file
    defmodule #{test_module} do
      @moduledoc \"\"\"
      SYNTHESIZED G4 FP-regression test (Security Sentinel E1.4).

      Pins the synthesized S3 (tree-wide) detector enforcing:
      #{escape_doc(spec.invariant)}

      Offending source is written to a tmp dir from an INERT STRING LITERAL (via
      inspect/1) — never raw-interpolated — so an adversarial interpolation
      payload in a scanned excerpt cannot execute when this file is compiled.
      \"\"\"
      use ExUnit.Case, async: true

      @moduletag :fast
      @moduletag :security

      @detector_source #{safe_literal(detector_source)}
      @detector_module #{safe_literal(detector_name)}

      setup_all do
        [{mod, _bin} | _] =
          Code.compile_string(
            String.replace(@detector_source, #{safe_literal(module_name)}, @detector_module)
          )

        {:ok, detector: mod}
      end

      setup do
        dir = Path.join(System.tmp_dir!(), "synth_g4_\#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf(dir) end)
        {:ok, dir: dir}
      end

      # `src` is an inert string literal; written (not interpolated) to disk.
      defp write(dir, name, src), do: File.write!(Path.join(dir, name), src)

      describe "positive — flags a confirmed sibling of the class" do
        test "the detector flags the confirmed offending source", %{detector: detector, dir: dir} do
          write(dir, "offender.ex", #{safe_literal(positive)})

          assert detector.detect(root: dir) != [],
                 "synthesized detector failed to flag a confirmed sibling"
        end
      end
    #{s3_fp_tests(fps)}end
    """
  end

  defp s3_fp_tests([]), do: ""

  defp s3_fp_tests(fps) do
    body =
      fps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {excerpt, i} ->
        """
            test "FP-regression #{i}: does NOT flag a refuted source", %{detector: detector, dir: dir} do
              write(dir, "clean_#{i}.ex", #{safe_literal(excerpt)})

              assert detector.detect(root: dir) == [],
                     "synthesized detector regressed: re-flagged a refuted false positive"
            end
        """
      end)

    """
      describe "FP-regression — stays quiet on refuted false positives" do
    #{body}  end
    """
  end

  # ---------------------------------------------------------------------------
  # Excerpt extraction (+ a spec-derived fallback so a positive always exists)
  # ---------------------------------------------------------------------------

  # The positive excerpt: the first confirmed sibling with a usable excerpt, else
  # a canonical offending shape derived from the spec (so the generated test
  # always has a meaningful positive assertion even if no excerpt was captured).
  defp positive_excerpt(spec, confirmed) do
    case Enum.find_value(confirmed, &excerpt_of/1) do
      nil -> fallback_offender(spec)
      excerpt -> excerpt
    end
  end

  # Read a code excerpt from a Finding (struct or map): evidence.code_excerpt.
  defp excerpt_of(finding) do
    ev = fetch(finding, :evidence) || %{}
    excerpt = fetch(ev, :code_excerpt)

    if is_binary(excerpt) and String.trim(excerpt) != "", do: excerpt, else: nil
  end

  # A canonical offending shape per shape/category, used only when no excerpt is
  # available. It is a plain string literal (it too is embedded via inspect/1).
  defp fallback_offender(%DetectorSpec{shape: :s3} = spec) do
    pattern_literal = s3_literal_string(spec)

    """
    defmodule SynthG4Offender do
      def #{fallback_fun(spec)} do
        #{pattern_literal}
      end
    end
    """
  end

  defp fallback_offender(%DetectorSpec{} = spec) do
    bad = fallback_return_literal(spec)

    """
    def #{fallback_fun(spec)}(arg) do
      do_work(arg)
    rescue
      _ -> #{bad}
    end
    """
  end

  # A function name guaranteed to satisfy the spec's name_match (so the fallback
  # offender is actually flagged): the first substring/exact, else "authorize".
  defp fallback_fun(%DetectorSpec{name_match: matches}) do
    case Enum.find(matches, &is_binary/1) do
      nil ->
        case Enum.find(matches, &is_atom/1) do
          nil -> "authorize"
          exact -> Atom.to_string(exact)
        end

      sub ->
        # substrings are pattern fragments; expand to a plausible function name
        sub <> "_check"
    end
  end

  # A source rendering of the first target literal for the S1 fallback.
  defp fallback_return_literal(%DetectorSpec{target_literals: [first | _]}),
    do: literal_to_source(first)

  defp fallback_return_literal(_), do: ":ok"

  # Render a target literal as Elixir source for the fallback offender. `{:ok, :_}`
  # (the wildcard form) becomes a concrete `{:ok, :resource}`.
  defp literal_to_source({:ok, :_}), do: "{:ok, :resource}"
  defp literal_to_source({a, :_}), do: "{#{literal_to_source(a)}, :wildcard}"
  defp literal_to_source(true), do: "true"
  defp literal_to_source(false), do: "false"
  defp literal_to_source(nil), do: "nil"
  defp literal_to_source(atom) when is_atom(atom), do: inspect(atom)
  defp literal_to_source(other), do: inspect(other)

  # A source string containing the S3 literal/call pattern (so the offender matches).
  defp s3_literal_string(%DetectorSpec{match_pattern: %{kind: :literal, literal: lit}})
       when is_binary(lit),
       do: inspect(lit <> "/everything")

  defp s3_literal_string(%DetectorSpec{match_pattern: %{kind: :literal, literal: {:ok, :_}}}),
    do: "{:ok, :resource}"

  defp s3_literal_string(%DetectorSpec{match_pattern: %{kind: :literal, literal: lit}}),
    do: literal_to_source(lit)

  defp s3_literal_string(%DetectorSpec{match_pattern: %{kind: :call, call: call}})
       when is_binary(call),
       do: call <> "(arg)"

  defp s3_literal_string(%DetectorSpec{match_pattern: %{kind: :call, call: call}})
       when is_atom(call),
       do: Atom.to_string(call) <> "(arg)"

  defp s3_literal_string(_), do: "\"arbor://**\""

  # ---------------------------------------------------------------------------
  # Names
  # ---------------------------------------------------------------------------

  @doc "The default generated test module name for a spec."
  @spec default_test_module(DetectorSpec.t()) :: String.t()
  def default_test_module(%DetectorSpec{shape: :s3, name: name}),
    do: "Arbor.Actions.Security.Detectors.Synthesized." <> camelize(name) <> "Test"

  def default_test_module(%DetectorSpec{name: name}),
    do: "Arbor.Eval.Checks.Synthesized." <> camelize(name) <> "Test"

  defp default_detector_compile_name(%DetectorSpec{shape: :s3, name: name}),
    do: "Arbor.Actions.Security.Detectors.Synthesized.G4_" <> camelize(name)

  defp default_detector_compile_name(%DetectorSpec{name: name}),
    do: "Arbor.Eval.Checks.Synthesized.G4_" <> camelize(name)

  # ---------------------------------------------------------------------------
  # Helpers (shared discipline with DetectorTemplate)
  # ---------------------------------------------------------------------------

  # Struct-aware field read: structs (Finding) don't implement Access, so use
  # Map.get; plain maps may carry atom- or string-keyed values.
  defp fetch(%_{} = struct, key) when is_atom(key), do: Map.get(struct, key)
  defp fetch(map, key) when is_map(map), do: map[key] || map[to_string(key)]
  defp fetch(_other, _key), do: nil

  # Render `value` as an INERT, fully-escaped Elixir string literal for embedding
  # in generated source. `printable_limit: :infinity` is MANDATORY — the default
  # (4096) truncates long source/excerpts into `"..." <> ...`, which is invalid
  # embedded source (and would also break the inert-literal guarantee). inspect/1
  # escapes `\#{}`, quotes, and newlines, so an adversarial excerpt becomes data,
  # never a live interpolation or a heredoc-escape.
  defp safe_literal(value),
    do: inspect(value, printable_limit: :infinity, limit: :infinity)

  # Neutralize anything that could break out of / inject into the generated
  # @moduledoc heredoc — identical discipline to DetectorTemplate.escape_doc/1.
  defp escape_doc(nil), do: ""

  defp escape_doc(str) when is_binary(str) do
    str
    |> String.replace(~s("""), "'''")
    |> String.replace("\"", "'")
    |> String.replace("\#{", "#_{")
  end

  defp camelize(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> Macro.camelize()
  end
end
