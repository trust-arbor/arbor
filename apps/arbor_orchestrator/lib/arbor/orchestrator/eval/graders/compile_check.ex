defmodule Arbor.Orchestrator.Eval.Graders.CompileCheck do
  @moduledoc """
  Grader that compiles Elixir code and scores based on compilation result.

  Scores:
    - 1.0 — compiles cleanly
    - 0.5 — compiles after injecting boilerplate (e.g., missing `use GenServer`)
    - 0.0 — fails to compile

  Options:
    - `:inject_boilerplate` — list of strings to try injecting if compilation fails
      (default: `["use GenServer"]`)
    - `:pass_threshold` — minimum score to pass (default: 0.5)
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @default_boilerplate ["use GenServer"]

  @impl true
  def grade(actual, _expected, opts \\ []) do
    code = extract_code(to_string(actual))
    boilerplate = Keyword.get(opts, :inject_boilerplate, @default_boilerplate)
    threshold = Keyword.get(opts, :pass_threshold, 0.5)

    case try_compile(code) do
      :ok ->
        %{score: 1.0, passed: true, detail: "compiles clean"}

      {:error, original_error} ->
        case try_with_boilerplate(code, boilerplate) do
          {:ok, injected} ->
            score = 0.5

            %{
              score: score,
              passed: score >= threshold,
              detail: "compiles with injected: #{injected}"
            }

          :failed ->
            %{score: 0.0, passed: false, detail: "compilation failed: #{original_error}"}
        end
    end
  end

  @doc "Extracts code from markdown fences if present."
  def extract_code(text) do
    case Regex.run(~r/```elixir\n(.*?)```/s, text) do
      [_, code] ->
        String.trim(code)

      nil ->
        case Regex.run(~r/```\n(.*?)```/s, text) do
          [_, code] -> String.trim(code)
          nil -> String.trim(text)
        end
    end
  end

  defp try_compile(code) do
    # Eval grader: compiles LLM-generated code in sandboxed eval context
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    Code.compile_string(code)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  after
    purge_compiled_modules(code)
  end

  defp try_with_boilerplate(code, boilerplate) do
    Enum.find_value(boilerplate, :failed, fn bp ->
      injected_code = inject_after_defmodule(code, bp)

      case try_compile_silent(injected_code) do
        :ok -> {:ok, bp}
        _ -> nil
      end
    end)
  end

  defp try_compile_silent(code) do
    # Eval grader: compiles LLM-generated code with boilerplate injection
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    Code.compile_string(code)
    :ok
  rescue
    _ -> :error
  catch
    _, _ -> :error
  after
    purge_compiled_modules(code)
  end

  defp inject_after_defmodule(code, boilerplate) do
    # Insert boilerplate after the first `defmodule ... do` line
    case Regex.run(~r/(defmodule\s+\S+\s+do\s*\n)/s, code) do
      [match, _] ->
        String.replace(code, match, match <> "  " <> boilerplate <> "\n", global: false)

      nil ->
        code
    end
  end

  defp purge_compiled_modules(code) do
    # Extract module names and clean up
    Regex.scan(~r/defmodule\s+([A-Z][\w.]+)/, code)
    |> Enum.each(fn [_, name] ->
      module = Module.concat([name])
      :code.purge(module)
      :code.delete(module)
    end)
  end
end
