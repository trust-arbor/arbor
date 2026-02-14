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
      Code.compile_string(munged_code)

      results =
        Enum.map(tests, fn test_case ->
          run_single_test(test_case, module_map, timeout)
        end)

      passed_count = Enum.count(results, & &1.passed)
      total = length(results)
      score = if total > 0, do: passed_count / total, else: 0.0

      details =
        results
        |> Enum.map(fn r ->
          status = if r.passed, do: "PASS", else: "FAIL"
          "#{status}: #{r.call} — #{r.detail}"
        end)
        |> Enum.join("; ")

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
        try do
          # Run setup if present
          bindings =
            if setup != "" do
              {_result, bindings} = Code.eval_string(setup)
              bindings
            else
              []
            end

          # Run the call
          {actual, _} = Code.eval_string(call, bindings)

          # Check result
          cond do
            match_pattern ->
              pattern = rewrite_module_refs(match_pattern, module_map)
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

            expect ->
              {expected_val, _} = Code.eval_string(expect)

              if actual == expected_val do
                %{passed: true, call: call, detail: "== #{expect}"}
              else
                %{
                  passed: false,
                  call: call,
                  detail: "expected #{expect}, got: #{inspect(actual)}"
                }
              end

            true ->
              # No expectation — just check it doesn't crash
              %{passed: true, call: call, detail: "no crash"}
          end
        rescue
          e -> %{passed: false, call: call, detail: "error: #{Exception.message(e)}"}
        catch
          kind, reason -> %{passed: false, call: call, detail: "#{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> %{passed: false, call: call, detail: "timeout after #{timeout}ms"}
    end
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

    # Replace in code (longest names first to avoid partial matches)
    munged_code =
      module_map
      |> Enum.sort_by(fn {name, _} -> -String.length(name) end)
      |> Enum.reduce(code, fn {original, munged}, acc ->
        String.replace(acc, original, munged)
      end)

    {munged_code, module_map}
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
