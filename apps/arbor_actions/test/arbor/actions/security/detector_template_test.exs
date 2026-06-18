# credo:disable-for-this-file
defmodule Arbor.Actions.Security.DetectorTemplateTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.{DetectorSpec, DetectorTemplate}

  # Compile a freshly-generated module under a unique name so tests don't clash.
  defp compile(spec) do
    name = "Arbor.Eval.Checks.Synthesized.Test_#{System.unique_integer([:positive])}"
    src = DetectorTemplate.s1_module_source(spec, module: name)
    [{mod, _bin} | _] = Code.compile_string(src)
    mod
  end

  defp authz_spec(overrides \\ %{}) do
    {:ok, spec} =
      DetectorSpec.build(
        Map.merge(
          %{
            category: :fail_open_authz,
            invariant: "Authorization must fail closed.",
            name_match: ["authoriz", :can?],
            target_literals: [:ok, true, :authorized, {:ok, :_}],
            exclusions: [{:ok, :verified}],
            clause_position: :rescue_or_catch_all
          },
          overrides
        )
      )

    spec
  end

  describe "generated source" do
    test "compiles and exposes the Arbor.Eval contract + category/0" do
      mod = compile(authz_spec())
      assert function_exported?(mod, :run, 1)
      assert function_exported?(mod, :__eval_info__, 0)
      assert mod.category() == :fail_open_authz
      assert mod.__eval_info__().category == :security
    end

    test "run/1 with no ast returns the no_ast error shape" do
      mod = compile(authz_spec())
      result = mod.run(%{})
      assert result.passed == false
      assert [%{type: :no_ast}] = result.violations
    end
  end

  describe "generated detector behavior (matches the AuthorizationSmells shape)" do
    test "flags a target fn rescuing to a banned literal" do
      mod = compile(authz_spec())

      ast =
        quote do
          def authorize(a, b) do
            do_check(a, b)
          rescue
            _ -> :ok
          end
        end

      result = mod.run(%{ast: ast})

      assert [v] = result.violations
      assert v.type == :rescue_returns_target
      assert v.function == "authorize"
      assert v.severity == :warning
      assert is_binary(v.message)
    end

    test "honors the {:ok, _} wildcard but carves out the exclusion" do
      mod = compile(authz_spec())

      flagged =
        quote do
          def authorize(c) do
            run(c)
          rescue
            _ -> {:ok, :anything}
          end
        end

      excluded =
        quote do
          def authorize(c) do
            run(c)
          rescue
            _ -> {:ok, :verified}
          end
        end

      assert [_] = mod.run(%{ast: flagged}).violations
      assert [] == mod.run(%{ast: excluded}).violations
    end

    test "does not flag a non-target function name" do
      mod = compile(authz_spec())

      ast =
        quote do
          def render(c) do
            build(c)
          rescue
            _ -> :ok
          end
        end

      assert [] == mod.run(%{ast: ast}).violations
    end

    test "does not flag a deny return from the fail-open clause" do
      mod = compile(authz_spec())

      ast =
        quote do
          def authorize(c) do
            run(c)
          rescue
            _ -> {:error, :denied}
          end
        end

      assert [] == mod.run(%{ast: ast}).violations
    end

    test "clause_position :catch_all only inspects case catch-alls, not rescue" do
      mod = compile(authz_spec(%{clause_position: :catch_all}))

      rescue_ast =
        quote do
          def authorize(c) do
            run(c)
          rescue
            _ -> :ok
          end
        end

      case_ast =
        quote do
          def authorize(c) do
            case run(c) do
              {:ok, _} -> :ok
              _ -> :ok
            end
          end
        end

      assert [] == mod.run(%{ast: rescue_ast}).violations
      assert [%{type: :catchall_returns_target}] = mod.run(%{ast: case_ast}).violations
    end
  end

  describe "security regression: generated source is injection-safe" do
    test "an invariant containing #{} interpolation does NOT execute at compile time" do
      # The invariant can come from an LLM-supplied (finding-derived) spec, and the
      # generated source is Code.compile_string'd. If the @moduledoc interpolated it
      # raw, this payload would run File.write! at compile time. The fix neutralizes
      # #{...} (and """ / ") in escape_doc. This test MUST fail on the pre-fix code.
      sentinel =
        Path.join(System.tmp_dir!(), "synth_injection_#{System.unique_integer([:positive])}")

      File.rm_rf(sentinel)
      on_exit(fn -> File.rm_rf(sentinel) end)

      # invariant VALUE = `pre #{File.write!("<sentinel>", "pwned")} post`
      payload =
        "pre " <>
          "\#{File.write!(" <> inspect(sentinel) <> ", \"pwned\")} post"

      mod = compile(authz_spec(%{invariant: payload}))

      refute File.exists?(sentinel),
             "code-injection: an #{} payload in the invariant executed when the " <>
               "generated detector source was compiled"

      # And the detector still compiled + works normally despite the hostile text.
      assert mod.category() == :fail_open_authz
      assert function_exported?(mod, :run, 1)
    end

    test "an invariant containing a heredoc terminator does not break out / inject" do
      # A `"""` in the invariant must not close the generated @moduledoc heredoc and
      # let following text become code. escape_doc rewrites `"""` -> `'''`.
      sentinel =
        Path.join(System.tmp_dir!(), "synth_heredoc_#{System.unique_integer([:positive])}")

      File.rm_rf(sentinel)
      on_exit(fn -> File.rm_rf(sentinel) end)

      payload =
        "x \"\"\"\n  def __injected__, do: File.write!(" <>
          inspect(sentinel) <> ", \"x\")\n  @moduledoc \"\"\"y"

      mod = compile(authz_spec(%{invariant: payload}))

      refute File.exists?(sentinel), "heredoc break-out injected/ran code"

      refute function_exported?(mod, :__injected__, 0),
             "heredoc break-out defined an injected function"

      assert mod.category() == :fail_open_authz
    end
  end
end
