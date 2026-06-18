# credo:disable-for-this-file
defmodule Arbor.Actions.Security.DetectorTemplateS3Test do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.{DetectorSpec, DetectorTemplate}

  # Compile a freshly-generated S3 module under a unique name so tests don't clash.
  defp compile(spec) do
    name =
      "Arbor.Actions.Security.Detectors.Synthesized.S3Test_#{System.unique_integer([:positive])}"

    src = DetectorTemplate.s3_module_source(spec, module: name)
    [{mod, _bin} | _] = Code.compile_string(src)
    mod
  end

  defp s3_spec(overrides) do
    {:ok, spec} =
      DetectorSpec.build(
        Map.merge(
          %{
            category: :capability_overmatch,
            invariant: "No over-broad capability pattern."
          },
          overrides
        )
      )

    spec
  end

  # Write a tmp tree with the given file contents; returns the dir.
  defp tree(files) do
    dir = Path.join(System.tmp_dir!(), "s3tpl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, content} -> File.write!(Path.join(dir, name), content) end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "generated source — contract" do
    test "compiles and exposes detect/1 + category/0" do
      mod = compile(s3_spec(%{match_pattern: %{kind: :literal, literal: "arbor://**"}}))
      assert function_exported?(mod, :detect, 1)
      assert function_exported?(mod, :category, 0)
      assert mod.category() == :capability_overmatch
    end

    test "detect/1 on an empty tree returns []" do
      mod = compile(s3_spec(%{match_pattern: %{kind: :literal, literal: "arbor://**"}}))
      assert [] == mod.detect(root: tree([]))
    end
  end

  describe ":literal pattern — tree-wide string match" do
    test "flags a file containing the forbidden literal anywhere" do
      mod = compile(s3_spec(%{match_pattern: %{kind: :literal, literal: "arbor://**"}}))

      dir =
        tree(%{
          "bad.ex" => ~s|defmodule Bad do\n  def grant, do: "arbor://**/extra"\nend\n|,
          "ok.ex" => ~s|defmodule Ok do\n  def grant, do: "arbor://fs/read"\nend\n|
        })

      findings = mod.detect(root: dir)
      assert [f] = findings
      assert f.category == :capability_overmatch
      assert String.ends_with?(f.location[:file], "bad.ex")
      assert is_binary(f.invariant_violated)
    end

    test "honors exclusions (a literal that looks banned but is carved out)" do
      mod =
        compile(
          s3_spec(%{
            match_pattern: %{kind: :literal, literal: "arbor://"},
            exclusions: ["arbor://fs/read"]
          })
        )

      dir = tree(%{"x.ex" => ~s|defmodule X do\n  def u, do: "arbor://fs/read"\nend\n|})
      assert [] == mod.detect(root: dir)
    end

    test "scopes to name_match functions when present" do
      mod =
        compile(
          s3_spec(%{
            match_pattern: %{kind: :literal, literal: "arbor://**"},
            name_match: ["grant"]
          })
        )

      dir =
        tree(%{
          "x.ex" =>
            ~s|defmodule X do\n  def grant, do: "arbor://**/a"\n  def render, do: "arbor://**/b"\nend\n|
        })

      findings = mod.detect(root: dir)
      # Only the match inside `grant` is reported (render is out of scope).
      assert [f] = findings
      assert f.location[:function] == "grant"
    end
  end

  describe ":call pattern — tree-wide call match" do
    test "flags a remote call Mod.fun(...) at its line" do
      mod = compile(s3_spec(%{match_pattern: %{kind: :call, call: "String.to_atom"}}))

      dir =
        tree(%{"c.ex" => ~s|defmodule C do\n  def f(s) do\n    String.to_atom(s)\n  end\nend\n|})

      assert [f] = mod.detect(root: dir)
      assert f.location[:line] == 3
    end

    test "does not flag a different call" do
      mod = compile(s3_spec(%{match_pattern: %{kind: :call, call: "String.to_atom"}}))

      dir =
        tree(%{"c.ex" => ~s|defmodule C do\n  def f(s), do: String.to_existing_atom(s)\nend\n|})

      assert [] == mod.detect(root: dir)
    end
  end

  describe "security regression: generated S3 source is injection-safe" do
    test "an invariant containing #{} interpolation does NOT execute when compiled" do
      # The invariant can come from an LLM-supplied (finding-derived) spec, and the
      # S3 source is Code.compile_string'd (same risk as S1). The @moduledoc /
      # @invariant_text must neutralize #{...} via escape_doc / inspect. This test
      # MUST fail if the hardening were removed (raw interpolation would run
      # File.write! at compile time).
      sentinel =
        Path.join(System.tmp_dir!(), "s3_inj_#{System.unique_integer([:positive])}")

      File.rm_rf(sentinel)
      on_exit(fn -> File.rm_rf(sentinel) end)

      payload =
        "pre " <>
          "\#{File.write!(" <> inspect(sentinel) <> ", \"pwned\")} post"

      mod =
        compile(
          s3_spec(%{
            invariant: payload,
            match_pattern: %{kind: :literal, literal: "arbor://**"}
          })
        )

      refute File.exists?(sentinel),
             "code-injection: an #{} payload in the S3 invariant executed at compile time"

      assert mod.category() == :capability_overmatch
      assert function_exported?(mod, :detect, 1)
    end

    test "an invariant with a heredoc terminator does not break out of @moduledoc" do
      sentinel =
        Path.join(System.tmp_dir!(), "s3_heredoc_#{System.unique_integer([:positive])}")

      File.rm_rf(sentinel)
      on_exit(fn -> File.rm_rf(sentinel) end)

      payload =
        "x \"\"\"\n  def __injected__, do: File.write!(" <>
          inspect(sentinel) <> ", \"x\")\n  @moduledoc \"\"\"y"

      mod =
        compile(
          s3_spec(%{
            invariant: payload,
            match_pattern: %{kind: :literal, literal: "arbor://**"}
          })
        )

      refute File.exists?(sentinel), "heredoc break-out injected/ran code"
      refute function_exported?(mod, :__injected__, 0), "heredoc break-out defined a function"
      assert mod.category() == :capability_overmatch
    end
  end
end
