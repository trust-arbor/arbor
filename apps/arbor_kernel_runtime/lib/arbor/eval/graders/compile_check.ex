defmodule Arbor.Eval.Graders.CompileCheck do
  @moduledoc """
  Grader that checks Elixir source syntax without loading or executing it.

  Scores:
    - 1.0 — parses cleanly
    - 0.5 — parses after injecting boilerplate (e.g., missing `use GenServer`)
    - 0.0 — fails to parse

  This module deliberately does not call `Code.compile_string/1`. Eval subjects
  are untrusted model or dataset output, and compiling them in the kernel VM
  executes module bodies and macros with the Arbor user's authority. Runtime
  compilation belongs in a separately isolated evaluator.

  ## Options

  - `:inject_boilerplate` - list of strings to try injecting if compilation fails
    (default: `["use GenServer"]`)
  - `:pass_threshold` - minimum score to pass (default: 0.5)
  """

  @behaviour Arbor.Eval.Grader

  @default_boilerplate ["use GenServer"]

  @impl true
  def grade(actual, _expected, opts \\ []) do
    code = extract_code(to_string(actual))
    boilerplate = Keyword.get(opts, :inject_boilerplate, @default_boilerplate)
    threshold = Keyword.get(opts, :pass_threshold, 0.5)

    case try_parse(code) do
      :ok ->
        %{score: 1.0, passed: true, detail: "syntax parses cleanly; execution not performed"}

      {:error, original_error} ->
        case try_with_boilerplate(code, boilerplate) do
          {:ok, injected} ->
            score = 0.5

            %{
              score: score,
              passed: score >= threshold,
              detail: "syntax parses with injected: #{injected}; execution not performed"
            }

          :failed ->
            %{score: 0.0, passed: false, detail: "syntax parsing failed: #{original_error}"}
        end
    end
  end

  @doc "Extracts code from markdown fences if present."
  def extract_code(text) do
    text
    |> normalize_line_endings()
    |> strip_thinking_blocks()
    |> extract_fenced_code()
  end

  defp normalize_line_endings(text) do
    text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
  end

  defp strip_thinking_blocks(text) do
    Regex.replace(~r/<think>.*?<\/think>\s*/s, text, "")
  end

  defp extract_fenced_code(text) do
    # Try ```elixir with optional spaces around language name (case-insensitive)
    case Regex.run(~r/```\s*elixir\s*\n(.*?)```/si, text) do
      [_, code] ->
        String.trim(code)

      nil ->
        # Try bare ``` fence
        case Regex.run(~r/```\s*\n(.*?)```/s, text) do
          [_, code] -> String.trim(code)
          nil -> String.trim(text)
        end
    end
  end

  defp try_parse(code) do
    case Code.string_to_quoted(code, existing_atoms_only: true) do
      {:ok, _quoted} -> :ok
      {:error, {_line, error, token}} -> {:error, Exception.format_banner(:error, error, token)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp try_with_boilerplate(code, boilerplate) do
    Enum.find_value(boilerplate, :failed, fn bp ->
      injected_code = inject_after_defmodule(code, bp)

      case try_parse(injected_code) do
        :ok -> {:ok, bp}
        _ -> nil
      end
    end)
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
end
