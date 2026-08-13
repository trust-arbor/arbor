defmodule Arbor.Actions.Coding.SecurityRegression.FormatterTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.SecurityRegression.Formatter

  @moduletag :fast
  @moduletag :security_regression

  @module_name "ArborSecurityRegressionFormatter.M" <> String.duplicate("A", 32)

  test "security regression: mix run argv keeps leading -- before owner result path" do
    # Exact owner form after Mix.Tasks.Run: script argv retains the `--`
    # separator that precedes the owner-issued result.etf path.
    assert {:ok, "/private/tmp/val/result/result.etf", ["test/a_test.exs"]} =
             Formatter.normalize_runner_argv([
               "--",
               "/private/tmp/val/result/result.etf",
               "test/a_test.exs"
             ])

    # Already-stripped form remains valid for pure fixtures.
    assert {:ok, "/private/tmp/val/result/result.etf", ["test/a_test.exs", "test/b_test.exs"]} =
             Formatter.normalize_runner_argv([
               "/private/tmp/val/result/result.etf",
               "test/a_test.exs",
               "test/b_test.exs"
             ])

    # Treating `--` itself as the artifact path is the false source_changed footgun.
    assert {:error, :missing_artifact_path} = Formatter.normalize_runner_argv([])
    assert {:error, :missing_artifact_path} = Formatter.normalize_runner_argv(["--"])

    assert {:error, :empty_test_paths} =
             Formatter.normalize_runner_argv(["--", "/private/tmp/val/result/result.etf"])

    assert {:error, :option_shaped_artifact_path} =
             Formatter.normalize_runner_argv(["--", "-e", "test/a_test.exs"])
  end

  test "security regression: generated runner stores owner path before Mix.Task.run; suite_finished never rereads argv" do
    assert {:ok, source} = Formatter.runner_source(@module_name)

    # One-time argv parse + strip at script body, then store before Mix.
    assert source =~ "case System.argv() do"
    assert source =~ ~s(["--" | rest] -> rest)
    assert source =~ "store_artifact_path!(artifact_path)"
    assert source =~ "Mix.Task.run(\"test\""

    # Formatter-owned state holds the path; suite_finished must not touch argv.
    assert source =~ "artifact_path: artifact_path"
    assert source =~ "Map.fetch!(state, :artifact_path)"
    assert source =~ "security-regression runner missing stored artifact path"
    assert source =~ "valid_owner_artifact_path?"

    # Remote calls must not appear in guards (Elixir 1.19 rejects them).
    refute source =~ ~r/when[^\n]*String\.starts_with\?/
    refute source =~ ~r/when[^\n]*not String\.starts_with\?/

    suite_finished =
      source
      |> String.split("def handle_cast({:suite_finished")
      |> Enum.at(1)
      |> String.split("def handle_cast(_event")
      |> hd()

    refute suite_finished =~ "System.argv()"
    refute source =~ ~r/\[artifact_path \| _tests\] = System\.argv\(\)/
    refute source =~ ~r/\[artifact_path \| test_paths\] = System\.argv\(\)/
  end

  test "security regression: generated Mix args include validator-owned test tag before exact paths" do
    flags = Formatter.mix_test_flags(@module_name)

    assert Enum.take(flags, -2) == ["--include", "test"]
    refute "--exclude" in flags
    refute "--only" in flags
    refute Enum.any?(flags, &String.contains?(&1, "database"))
    refute Enum.any?(flags, &String.contains?(&1, "integration"))
    refute Enum.any?(flags, &String.contains?(&1, "llm"))

    assert {:ok, source} = Formatter.runner_source(@module_name)
    mix_args = extract_mix_test_run_args!(source)

    assert List.last(mix_args) == :test_paths
    assert Enum.drop(mix_args, -1) == flags

    include_index = Enum.find_index(mix_args, &(&1 == "--include"))
    assert is_integer(include_index)
    assert Enum.at(mix_args, include_index + 1) == "test"
    assert include_index < length(mix_args) - 1
    assert Enum.at(mix_args, -1) == :test_paths
  end

  test "security regression: ExUnit include test overrides helper exclusions" do
    # Current Elixir: every test carries `:test` (the test name). Include is
    # evaluated before exclude, so `--include test` runs helper-excluded tests
    # already loaded from exact selected paths. `@tag :skip` stays skipped.
    tags = %{test: :guest_remains_denied, helper_excluded: true}

    assert :ok = ExUnit.Filters.eval([:test], [:helper_excluded], tags, [])

    without_include = ExUnit.Filters.eval([], [:helper_excluded], tags, [])
    assert without_include != :ok
    assert elem(without_include, 0) in [:excluded, :error]
  end

  test "security regression: generated formatter module compiles under pinned Elixir" do
    # Behavioral compile of the formatter GenServer only — not the script tail
    # that would invoke Mix.Task.run. Proves String.starts_with?/2 is not in a
    # guard and the store/init path is loadable.
    module_name =
      "ArborSecurityRegressionFormatter.M" <>
        (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :upper))

    assert {:ok, source} = Formatter.runner_source(module_name)
    module_ast = extract_defmodule_ast!(source)

    compiled =
      try do
        Code.compile_quoted(module_ast)
      rescue
        error ->
          flunk(
            "generated security-regression runner failed to compile: #{Exception.message(error)}"
          )
      end

    assert [{mod, _beam} | _] = compiled
    assert mod == String.to_existing_atom("Elixir." <> module_name)

    artifact = "/private/tmp/arbor-val/result/result.etf"
    assert :ok = mod.store_artifact_path!(artifact)
    assert {:ok, state} = mod.init([])
    assert state.artifact_path == artifact

    assert_raise RuntimeError, ~r/missing artifact path/, fn ->
      mod.store_artifact_path!("--")
    end

    assert_raise RuntimeError, ~r/missing artifact path/, fn ->
      mod.store_artifact_path!("-e")
    end

    :code.purge(mod)
    :code.delete(mod)
  end

  defp extract_mix_test_run_args!(source) when is_binary(source) do
    assert {:ok, ast} = Code.string_to_quoted(source)

    forms =
      case ast do
        {:__block__, _meta, quoted} when is_list(quoted) -> quoted
        form -> [form]
      end

    args_ast =
      Enum.find_value(forms, fn
        {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Mix, :Task]}, :run]}, _meta,
         ["test", list]} ->
          list

        _other ->
          nil
      end)

    assert args_ast
    flatten_quoted_cons(args_ast)
  end

  defp flatten_quoted_cons({:|, _meta, [head, tail]}) do
    flatten_quoted_cons(head) ++ flatten_quoted_cons(tail)
  end

  defp flatten_quoted_cons(list) when is_list(list) do
    Enum.flat_map(list, &flatten_quoted_cons/1)
  end

  defp flatten_quoted_cons({name, _meta, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)) do
    [name]
  end

  defp flatten_quoted_cons(literal) when is_binary(literal) or is_atom(literal) do
    [literal]
  end

  defp extract_defmodule_ast!(source) when is_binary(source) do
    assert {:ok, ast} = Code.string_to_quoted(source)

    module_ast =
      case ast do
        {:__block__, _meta, forms} when is_list(forms) ->
          Enum.find(forms, &match?({:defmodule, _, _}, &1))

        {:defmodule, _, _} = form ->
          form

        _other ->
          nil
      end

    assert is_tuple(module_ast)
    module_ast
  end
end
