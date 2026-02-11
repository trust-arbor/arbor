defmodule Arbor.Orchestrator.Eval.Subjects.SpecToDot do
  @moduledoc """
  Subject that generates a .dot pipeline file from a spec section.

  Takes a spec text (or map with subsystem metadata) as input, calls the LLM
  to generate a pipeline DOT file, and returns the DOT string.

  Uses the Arbor.AI runtime bridge when available, otherwise returns a
  simulated minimal pipeline.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @impl true
  def run(input, opts \\ []) do
    prompt = build_prompt(input)

    case call_llm(prompt, opts) do
      {:ok, response} -> {:ok, extract_dot(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_prompt(input) when is_binary(input) do
    build_prompt(%{"spec" => input, "goal" => "Implement the specified subsystem", "files" => []})
  end

  defp build_prompt(%{} = input) do
    spec = input["subsystem"] || input["spec"] || ""
    goal = input["goal"] || "Implement the specified subsystem"
    files = input["files"] || []

    file_count = length(files)

    files_section =
      case files do
        [] -> "Not specified"
        list -> Enum.join(list, "\n")
      end

    node_guidance =
      cond do
        file_count <= 3 ->
          "Use 1 impl node that implements all #{file_count} files together."

        file_count <= 6 ->
          "Use 2 impl nodes, grouping related files together (e.g., impl_1 for core modules, impl_2 for supporting modules)."

        true ->
          "Use 3 impl nodes, grouping related files by concern (e.g., core, support, utilities). Do NOT create one node per file."
      end

    """
    You are generating a pipeline DOT file following the Arbor Orchestrator DSL.

    GOAL: #{goal}

    FILES TO IMPLEMENT (#{file_count} files):
    #{files_section}

    SPECIFICATION:
    #{spec}

    Generate a complete digraph following this DSL:
    - graph [goal="..."] attribute matching the goal
    - start [shape=Mdiamond] entry point
    - impl_N [shape=box, prompt="..."] implementation nodes. #{node_guidance}
    - write_tests [shape=box, prompt="Write comprehensive ExUnit tests..."]
    - compile [shape=parallelogram, tool_command="mix compile --warnings-as-errors"]
    - run_tests [shape=parallelogram, tool_command="mix test"]
    - quality [shape=diamond, goal_gate=true, retry_target="impl_1"]
    - done [shape=Msquare]
    - Edges: the forward chain PLUS the retry back-edge:
      start -> impl_1 -> ... -> write_tests -> compile -> run_tests -> quality
      quality -> done [condition="outcome=success"]
      quality -> impl_1 [condition="outcome=fail", label="retry"]

    IMPORTANT: Match the expected structure — use exactly the node types listed above.
    Group related modules into fewer impl nodes rather than splitting per-file.
    You MUST include both quality gate edges (success forward + fail retry).

    Output ONLY the DOT file content, no markdown fences or commentary.\
    """
  end

  defp call_llm(prompt, opts) do
    cond do
      Keyword.get(opts, :simulate, false) ->
        {:ok, simulated_response()}

      Code.ensure_loaded?(Arbor.AI) ->
        call_arbor_ai(prompt, opts)

      true ->
        {:ok, simulated_response()}
    end
  end

  defp call_arbor_ai(prompt, opts) do
    ai_opts =
      Keyword.take(opts, [:model, :provider, :max_tokens, :temperature])

    case apply(Arbor.AI, :generate_text_via_cli, [prompt, ai_opts]) do
      {:ok, response} when is_map(response) ->
        {:ok, Map.get(response, :text, Map.get(response, "text", ""))}

      {:ok, text} when is_binary(text) ->
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp simulated_response do
    """
    digraph T {
      graph [goal="Simulated"]
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """
  end

  defp extract_dot(response) do
    # First try: strip markdown code fences
    stripped =
      response
      |> String.replace(~r/\A\s*```(?:dot|graphviz)?\n/, "")
      |> String.replace(~r/\n```\s*\z/, "")
      |> String.trim()

    if String.starts_with?(stripped, "digraph") do
      stripped
    else
      # Extract embedded digraph from narrative text using balanced braces
      case Regex.run(~r/digraph\s+\w+\s*\{/s, response) do
        [match] ->
          start_idx = :binary.match(response, match) |> elem(0)
          rest = binary_part(response, start_idx, byte_size(response) - start_idx)
          extract_balanced_braces(rest)

        nil ->
          stripped
      end
    end
  end

  defp extract_balanced_braces(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn char, {depth, acc} ->
      new_depth =
        case char do
          "{" -> depth + 1
          "}" -> depth - 1
          _ -> depth
        end

      new_acc = [char | acc]

      if new_depth == 0 and depth > 0 do
        {:halt, {0, new_acc}}
      else
        {:cont, {new_depth, new_acc}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
  end
end
