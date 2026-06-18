# credo:disable-for-this-file
defmodule Arbor.Actions.Security.DetectorTestTemplateTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  alias Arbor.Actions.Security.{DetectorSpec, DetectorTemplate, DetectorTestTemplate}
  alias Arbor.Contracts.Security.Finding

  # Build an S1 spec + its detector source (the fail-open authz shape).
  defp s1_spec do
    {:ok, spec} =
      DetectorSpec.build(%{
        name: "g4_authz",
        category: :fail_open_authz,
        invariant: "Authorization must fail closed.",
        name_match: ["authoriz"],
        target_literals: [:ok, true, {:ok, :_}],
        exclusions: [],
        clause_position: :rescue_or_catch_all
      })

    spec
  end

  defp s1_detector_source(spec, module_name),
    do: DetectorTemplate.s1_module_source(spec, module: module_name)

  # Build an S3 spec + its detector source (the over-broad-capability shape).
  defp s3_spec do
    {:ok, spec} =
      DetectorSpec.build(%{
        shape: :s3,
        name: "g4_overmatch",
        category: :capability_overmatch,
        invariant: "Capabilities must not grant arbor://** (over-broad).",
        match_pattern: %{kind: :literal, literal: "arbor://**"},
        name_match: ["grant"]
      })

    spec
  end

  defp s3_detector_source(spec, module_name),
    do: DetectorTemplate.s3_module_source(spec, module: module_name)

  defp confirmed_finding(excerpt) do
    Finding.new(
      category: :fail_open_authz,
      title: "confirmed sibling",
      location: %{file: "apps/x/lib/x.ex", function: "authorize_x"},
      evidence: %{code_excerpt: excerpt}
    )
  end

  defp refuted_finding(excerpt) do
    Finding.new(
      category: :fail_open_authz,
      title: "refuted FP",
      location: %{file: "apps/y/lib/y.ex", function: "noop"},
      evidence: %{code_excerpt: excerpt}
    )
  end

  # Compile a generated ExUnit test source. The generated module `use ExUnit.Case`,
  # so it auto-registers and ExUnit re-runs it at this suite's end — which is a
  # FEATURE: it proves end-to-end that the generated test's own positive/FP
  # assertions pass against the real detector. (Every excerpt fed here is
  # therefore chosen to make the generated test legitimately pass.)
  defp compile_generated(source) do
    [{mod, _bin} | _] = Code.compile_string(source)
    mod
  end

  describe "S1 generated test compiles + asserts correctly" do
    test "positive test flags a confirmed sibling; FP test stays quiet on a refuted excerpt" do
      spec = s1_spec()
      module_name = "Arbor.Eval.Checks.Synthesized.S1Under_#{System.unique_integer([:positive])}"
      detector_source = s1_detector_source(spec, module_name)

      confirmed_excerpt = """
      def authorize_request(agent, resource) do
        run_chain(agent, resource)
      rescue
        _ -> :ok
      end
      """

      # A fail-CLOSED authz fn — the detector must NOT flag it (refuted FP).
      refuted_excerpt = """
      def authorize_request(agent, resource) do
        run_chain(agent, resource)
      rescue
        _ -> {:error, :denied}
      end
      """

      test_module = "Arbor.Eval.Checks.Synthesized.G4S1Gen_#{System.unique_integer([:positive])}"

      source =
        DetectorTestTemplate.generate(
          spec,
          module_name,
          [confirmed_finding(confirmed_excerpt)],
          [refuted_finding(refuted_excerpt)],
          module_source: detector_source,
          test_module: test_module,
          detector_compile_name:
            "Arbor.Eval.Checks.Synthesized.Det1_#{System.unique_integer([:positive])}"
        )

      # The generated source compiles, and its own assertions hold: run it.
      mod = compile_generated(source)
      assert {:module, ^mod} = Code.ensure_compiled(mod)

      # Behaviorally exercise the embedded detector via the same idiom the
      # generated test uses (parse the inert excerpt → run/1).
      [{det, _} | _] =
        Code.compile_string(String.replace(detector_source, module_name, module_name <> "_chk"))

      pos_ast = Code.string_to_quoted!(confirmed_excerpt)
      neg_ast = Code.string_to_quoted!(refuted_excerpt)

      assert det.run(%{ast: pos_ast}).violations != []
      assert det.run(%{ast: neg_ast}).violations == []
    end

    test "falls back to a spec-derived offender when no excerpt is present" do
      spec = s1_spec()
      module_name = "Arbor.Eval.Checks.Synthesized.S1Fb_#{System.unique_integer([:positive])}"
      detector_source = s1_detector_source(spec, module_name)
      test_module = "Arbor.Eval.Checks.Synthesized.G4S1Fb_#{System.unique_integer([:positive])}"

      source =
        DetectorTestTemplate.generate(spec, module_name, [], [],
          module_source: detector_source,
          test_module: test_module,
          detector_compile_name:
            "Arbor.Eval.Checks.Synthesized.Det2_#{System.unique_integer([:positive])}"
        )

      # Compiles even with no siblings; the positive uses the spec fallback.
      assert is_binary(source)
      _mod = compile_generated(source)
    end
  end

  describe "S3 generated test compiles + asserts correctly" do
    test "positive flags a confirmed source; FP test stays quiet" do
      spec = s3_spec()

      module_name =
        "Arbor.Actions.Security.Detectors.Synthesized.S3Under_#{System.unique_integer([:positive])}"

      detector_source = s3_detector_source(spec, module_name)

      confirmed_excerpt = """
      defmodule Offender do
        def grant_all do
          "arbor://**/everything"
        end
      end
      """

      refuted_excerpt = """
      defmodule Clean do
        def grant_one do
          "arbor://fs/read/specific"
        end
      end
      """

      test_module =
        "Arbor.Actions.Security.Detectors.Synthesized.G4S3Gen_#{System.unique_integer([:positive])}"

      source =
        DetectorTestTemplate.generate(
          spec,
          module_name,
          [
            Finding.new(
              category: :capability_overmatch,
              title: "confirmed",
              location: %{file: "apps/x/lib/x.ex", function: "grant_all"},
              evidence: %{code_excerpt: confirmed_excerpt}
            )
          ],
          [
            Finding.new(
              category: :capability_overmatch,
              title: "refuted",
              location: %{file: "apps/y/lib/y.ex", function: "grant_one"},
              evidence: %{code_excerpt: refuted_excerpt}
            )
          ],
          module_source: detector_source,
          test_module: test_module,
          detector_compile_name:
            "Arbor.Actions.Security.Detectors.Synthesized.Det3_#{System.unique_integer([:positive])}"
        )

      assert is_binary(source)
      _mod = compile_generated(source)
    end
  end

  # ---------------------------------------------------------------------------
  # G4 INJECTION-REGRESSION: an excerpt carrying a #{...} payload must NOT
  # execute when the generated test source is compiled.
  # ---------------------------------------------------------------------------
  describe "G4 injection-regression — adversarial excerpts do not execute" do
    test "an interpolation payload in an excerpt does not run at compile time of the generated source" do
      spec = s1_spec()
      module_name = "Arbor.Eval.Checks.Synthesized.Inj_#{System.unique_integer([:positive])}"
      detector_source = s1_detector_source(spec, module_name)

      sentinel = Path.join(System.tmp_dir!(), "g4_pwned_#{System.unique_integer([:positive])}")
      File.rm_rf(sentinel)
      on_exit(fn -> File.rm_rf(sentinel) end)

      # An adversarial excerpt that is ALSO a flaggable fail-open authorize (so
      # the generated positive legitimately flags it), but carries a #{...}
      # injection payload as a string literal in its body. If the template
      # raw-interpolated the excerpt, that payload would execute when the
      # generated source is compiled. Built by concatenation so THIS file does
      # not itself interpolate it.
      interp_open = "\#" <> "{"

      payload =
        "def authorize(x) do\n" <>
          "  log(\"" <>
          interp_open <>
          "File.write!(\"" <>
          sentinel <>
          "\", \"pwned\")}\")\n" <>
          "  do_check(x)\n" <>
          "rescue\n" <>
          "  _ -> :ok\n" <>
          "end"

      test_module = "Arbor.Eval.Checks.Synthesized.G4Inj_#{System.unique_integer([:positive])}"

      source =
        DetectorTestTemplate.generate(
          spec,
          module_name,
          [confirmed_finding(payload)],
          [],
          module_source: detector_source,
          test_module: test_module,
          detector_compile_name:
            "Arbor.Eval.Checks.Synthesized.DetInj_#{System.unique_integer([:positive])}"
        )

      # The hardening guarantee: the payload appears in the source ONLY as an
      # escaped string literal (the #{} opener is backslash-escaped by inspect/1),
      # never as a live interpolation.
      refute String.contains?(source, "log(\"" <> interp_open <> "File.write!")
      assert String.contains?(source, "\\" <> interp_open <> "File.write!")

      # Compiling the generated source MUST NOT execute the payload.
      _mod = compile_generated(source)

      refute File.exists?(sentinel),
             "INJECTION: the interpolation payload executed at compile time — hardening failed"
    end

    test "WITHOUT hardening (raw interpolation), the same payload WOULD execute" do
      # This proves the injection-regression test above is meaningful: build the
      # naive raw-interpolated source by hand and confirm it DOES run the payload.
      sentinel = Path.join(System.tmp_dir!(), "g4_naive_#{System.unique_integer([:positive])}")
      File.rm_rf(sentinel)
      on_exit(fn -> File.rm_rf(sentinel) end)

      interp_open = "\#" <> "{"

      # The adversarial excerpt as inert text (no interpolation in THIS file).
      payload = "\"" <> interp_open <> "File.write!(\"" <> sentinel <> "\", \"pwned\")}\""

      naive_module = "Arbor.Eval.Checks.Synthesized.Naive_#{System.unique_integer([:positive])}"

      # The vulnerable shape the hardening prevents: the excerpt raw-interpolated
      # into a MODULE ATTRIBUTE (exactly where the real template embeds the
      # detector source / excerpt), so its #{} becomes a live interpolation
      # evaluated at COMPILE time. We assemble that naive source by concatenation.
      naive_source =
        "defmodule " <>
          naive_module <>
          " do\n  @offender " <> payload <> "\n  def offender, do: @offender\nend\n"

      Code.compile_string(naive_source)

      assert File.exists?(sentinel),
             "control failed: the naive raw-interpolated payload should have executed"
    end
  end
end
