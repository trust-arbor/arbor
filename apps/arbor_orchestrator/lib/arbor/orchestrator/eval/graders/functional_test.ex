defmodule Arbor.Orchestrator.Eval.Graders.FunctionalTest do
  @moduledoc """
  Grader that compiles code and exercises it with test assertions.

  The `expected` field should be a map with:
    - `"module"` — the module name (e.g., "KVStore")
    - `"tests"` — list of test maps, each with:
      - `"setup"` — optional setup code to run before the assertion
      - `"call"` — expression to evaluate (e.g., "KVStore.get(pid, :a)")
      - `"expect"` — expected result as a string (e.g., ":ok" or "nil")
      - `"match"` — alternative: pattern to match (e.g., "{:ok, _pid}")

  Score is the fraction of tests that pass (e.g., 5/6 = 0.833).

  Options:
    - `:timeout` — per-test timeout in ms (default: 5000)
    - `:pass_threshold` — minimum score to pass (default: 0.5)
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  alias Arbor.Orchestrator.Eval.Graders.CompileCheck

  @impl true
  def grade(actual, expected, opts \\ []) do
    code = CompileCheck.extract_code(to_string(actual))
    timeout = Keyword.get(opts, :timeout, 5_000)
    threshold = Keyword.get(opts, :pass_threshold, 0.5)

    tests = extract_tests(expected)

    if tests == [] do
      %{score: 0.0, passed: false, detail: "no test assertions in expected field"}
    else
      run_with_compiled_module(code, tests, timeout, threshold)
    end
  end

  defp extract_tests(%{"tests" => tests}) when is_list(tests), do: tests
  defp extract_tests(%{tests: tests}) when is_list(tests), do: tests
  defp extract_tests(_), do: []

  defp run_with_compiled_module(code, tests, timeout, threshold) do
    # Add unique suffix to avoid module name collisions
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    {munged_code, module_map} = munge_module_names(code, suffix)

    try do
      # Eval grader: compiles LLM-generated code for functional testing
      # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
      Code.compile_string(munged_code)

      results =
        Enum.map(tests, fn test_case ->
          run_single_test(test_case, module_map, timeout)
        end)

      passed_count = Enum.count(results, & &1.passed)
      total = length(results)
      score = if total > 0, do: passed_count / total, else: 0.0

      details =
        Enum.map_join(results, "; ", fn r ->
          status = if r.passed, do: "PASS", else: "FAIL"
          "#{status}: #{r.call} — #{r.detail}"
        end)

      %{
        score: score,
        passed: score >= threshold,
        detail: "#{passed_count}/#{total} tests passed. #{details}"
      }
    rescue
      e ->
        %{score: 0.0, passed: false, detail: "compilation failed: #{Exception.message(e)}"}
    catch
      kind, reason ->
        %{score: 0.0, passed: false, detail: "compilation error: #{kind}: #{inspect(reason)}"}
    after
      cleanup_modules(munged_code)
    end
  end

  defp run_single_test(test_case, module_map, timeout) do
    call = rewrite_module_refs(test_case["call"] || test_case[:call] || "", module_map)
    setup = rewrite_module_refs(test_case["setup"] || test_case[:setup] || "", module_map)
    expect = test_case["expect"] || test_case[:expect]
    match_pattern = test_case["match"] || test_case[:match]

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        execute_test_case(call, setup, expect, match_pattern, module_map)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        %{passed: false, call: call, detail: "timeout (exit: #{inspect(reason)})"}

      nil ->
        %{passed: false, call: call, detail: "timeout after #{timeout}ms"}
    end
  end

  defp execute_test_case(call, setup, expect, match_pattern, module_map) do
    try do
      bindings = run_setup(setup)

      # Eval grader: evaluates test call expression from eval spec
      # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
      {actual, _} = Code.eval_string(call, bindings)

      check_result(actual, call, expect, match_pattern, module_map)
    rescue
      e -> %{passed: false, call: call, detail: "error: #{Exception.message(e)}"}
    catch
      kind, reason -> %{passed: false, call: call, detail: "#{kind}: #{inspect(reason)}"}
    end
  end

  defp run_setup(""), do: []

  defp run_setup(setup) do
    # Eval grader: runs test setup code from eval spec
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    {_result, bindings} = Code.eval_string(setup)
    bindings
  end

  defp check_result(actual, call, _expect, match_pattern, module_map)
       when not is_nil(match_pattern) do
    pattern = rewrite_module_refs(match_pattern, module_map)
    # Eval grader: evaluates match? pattern from eval spec
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    {matches, _} = Code.eval_string("match?(#{pattern}, actual)", actual: actual)

    if matches do
      %{passed: true, call: call, detail: "matched #{match_pattern}"}
    else
      %{
        passed: false,
        call: call,
        detail: "expected match #{match_pattern}, got: #{inspect(actual)}"
      }
    end
  end

  defp check_result(actual, call, expect, _match_pattern, _module_map) when not is_nil(expect) do
    # Eval grader: evaluates expected value from eval spec
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    {expected_val, _} = Code.eval_string(expect)

    if actual == expected_val do
      %{passed: true, call: call, detail: "== #{expect}"}
    else
      %{passed: false, call: call, detail: "expected #{expect}, got: #{inspect(actual)}"}
    end
  end

  defp check_result(_actual, call, _expect, _match_pattern, _module_map) do
    %{passed: true, call: call, detail: "no crash"}
  end

  defp munge_module_names(code, suffix) do
    # Find all top-level module names
    module_names =
      Regex.scan(~r/defmodule\s+([A-Z][\w.]+)/, code)
      |> Enum.map(fn [_, name] -> name end)

    # Build mapping: original -> munged
    module_map =
      Map.new(module_names, fn name ->
        munged = "#{name}_Eval_#{suffix}"
        {name, munged}
      end)

    # Replace module references in code positions only (not inside string literals).
    # Match: defmodule Name, %Name{, Name., alias Name, @Name — i.e., preceded by
    # a non-alphanumeric char or start of line, and the name starts with uppercase.
    munged_code =
      module_map
      |> Enum.sort_by(fn {name, _} -> -String.length(name) end)
      |> Enum.reduce(code, fn {original, munged}, acc ->
        # Replace only at module-reference positions:
        # - After defmodule/defprotocol/defimpl/alias/require/import/use + whitespace
        # - After % (struct literal)
        # - After a dot-less word boundary (not inside a string)
        # We use a regex that matches the name preceded by a non-word, non-quote char
        # or at line start, and NOT inside a quoted string.
        replace_module_refs_in_code(acc, original, munged)
      end)

    {munged_code, module_map}
  end

  # Replace module name references while preserving string literals.
  # Splits code on string boundaries, only replaces in code segments.
  defp replace_module_refs_in_code(code, original, replacement) do
    # Split on double-quoted strings (preserving them)
    parts = Regex.split(~r/"(?:[^"\\]|\\.)*"/, code, include_captures: true)

    Enum.map_join(parts, fn part ->
      if String.starts_with?(part, "\"") do
        # Inside a string literal — don't touch
        part
      else
        # Code segment — replace module references
        String.replace(part, original, replacement)
      end
    end)
  end

  defp rewrite_module_refs(expr, module_map) do
    module_map
    |> Enum.sort_by(fn {name, _} -> -String.length(name) end)
    |> Enum.reduce(expr, fn {original, munged}, acc ->
      String.replace(acc, original, munged)
    end)
  end

  defp cleanup_modules(code) do
    Regex.scan(~r/defmodule\s+([A-Z][\w.]+)/, code)
    |> Enum.each(fn [_, name] ->
      module = Module.concat([name])
      :code.purge(module)
      :code.delete(module)
    end)
  end
end
