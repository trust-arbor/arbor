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

    files_section =
      case files do
        [] -> "Not specified"
        list -> Enum.join(list, "\n")
      end

    """
    You are generating a pipeline DOT file following the Arbor Orchestrator DSL.

    GOAL: #{goal}

    FILES TO IMPLEMENT:
    #{files_section}

    SPECIFICATION:
    #{spec}

    Generate a complete digraph following this DSL:
    - graph [goal="..."] attribute matching the goal
    - start [shape=Mdiamond] entry point
    - impl_N [prompt="..."] nodes with detailed prompts for each file
    - write_tests [prompt="Write comprehensive ExUnit tests..."]
    - compile [type="tool", tool_command="mix compile --warnings-as-errors"]
    - run_tests [type="tool", tool_command="mix test"]
    - quality [shape=diamond, goal_gate=true, retry_target="impl_1"]
    - done [shape=Msquare]
    - Edges chaining start -> impl_1 -> ... -> write_tests -> compile -> run_tests -> quality -> done

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
    response
    |> String.replace(~r/\A\s*```(?:dot|graphviz)?\n/, "")
    |> String.replace(~r/\n```\s*\z/, "")
    |> String.trim()
  end
end
