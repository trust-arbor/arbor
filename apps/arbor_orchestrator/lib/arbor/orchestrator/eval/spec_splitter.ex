defmodule Arbor.Orchestrator.Eval.SpecSplitter do
  @moduledoc """
  Splits attractor-spec.md into subsystem-specific sections for eval comparison.

  Maps spec sections to orchestrator subsystems, enabling comparison between
  spec-derived and source-code-derived .dot pipeline files.
  """

  @section_to_subsystems %{
    ~r/^## 2\. DOT DSL/m => ["dot"],
    ~r/^## 3\. Pipeline Execution/m => ["engine"],
    ~r/^## 4\. Node Handlers/m => ["handlers"],
    ~r/^## 5\. State and Context/m => ["engine"],
    ~r/^## 6\. Human-in-the-Loop/m => ["human"],
    ~r/^## 7\. Validation and Linting/m => ["validation", "ir"],
    ~r/^## 8\. Model Stylesheet/m => ["graph"],
    ~r/^## 9\. Transforms/m => ["transforms", "engine"],
    ~r/^## 10\. Condition Expression/m => ["graph"],
    ~r/^## 11\. (Meta-Handlers|Definition)/m => ["handlers"],
    ~r/^## 12\. Evaluation Framework/m => ["eval"]
  }

  @all_subsystems ~w(
    dot graph engine handlers validation ir
    human transforms eval unified_llm agent_loop
  )

  @doc """
  Splits a spec markdown file into a map of subsystem_name => spec text.

  Subsystems with no mapped sections get empty string "".
  """
  @spec split(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def split(spec_path) do
    case File.read(spec_path) do
      {:ok, content} ->
        sections = parse_sections(content)
        subsystem_map = build_subsystem_map(sections)
        {:ok, subsystem_map}

      {:error, reason} ->
        {:error, "Failed to read spec: #{inspect(reason)}"}
    end
  end

  @doc """
  Same as split/1 but prepends Section 1 (Overview and Goals) to every
  non-empty subsystem's text as shared context.
  """
  @spec split_with_preamble(String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def split_with_preamble(spec_path) do
    case File.read(spec_path) do
      {:ok, content} ->
        sections = parse_sections(content)
        subsystem_map = build_subsystem_map(sections)

        preamble =
          sections
          |> Enum.find(fn {title, _content} -> String.starts_with?(title, "1.") end)
          |> case do
            {_title, preamble_content} -> preamble_content
            nil -> ""
          end

        enriched_map =
          Map.new(subsystem_map, fn {subsystem, text} ->
            if text != "" and preamble != "" do
              {subsystem, preamble <> "\n\n---\n\n" <> text}
            else
              {subsystem, text}
            end
          end)

        {:ok, enriched_map}

      {:error, reason} ->
        {:error, "Failed to read spec: #{inspect(reason)}"}
    end
  end

  @doc "Returns subsystem names that have no spec coverage."
  @spec list_unmapped_subsystems(String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def list_unmapped_subsystems(spec_path) do
    case split(spec_path) do
      {:ok, subsystem_map} ->
        unmapped =
          subsystem_map
          |> Enum.filter(fn {_name, text} -> text == "" end)
          |> Enum.map(fn {name, _text} -> name end)
          |> Enum.sort()

        {:ok, unmapped}

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns the list of all known subsystem names."
  @spec all_subsystems() :: [String.t()]
  def all_subsystems, do: @all_subsystems

  # --- Private functions ---

  defp parse_sections(content) do
    parts = Regex.split(~r/^(## \d+\. .+)$/m, content, include_captures: true)

    parts
    |> chunk_sections([])
    |> Enum.reverse()
  end

  defp chunk_sections([], acc), do: acc

  defp chunk_sections([_preamble | rest], [] = acc) do
    chunk_heading_pairs(rest, acc)
  end

  defp chunk_heading_pairs([], acc), do: acc

  defp chunk_heading_pairs([heading, content | rest], acc) do
    title = String.replace_prefix(heading, "## ", "") |> String.trim()
    chunk_heading_pairs(rest, [{title, String.trim(content)} | acc])
  end

  defp chunk_heading_pairs([heading], acc) do
    title = String.replace_prefix(heading, "## ", "") |> String.trim()
    [{title, ""} | acc]
  end

  defp build_subsystem_map(sections) do
    initial = Map.new(@all_subsystems, fn name -> {name, ""} end)

    Enum.reduce(sections, initial, fn {title, content}, map ->
      subsystems = match_section_to_subsystems(title)

      Enum.reduce(subsystems, map, fn subsystem, acc ->
        current = Map.get(acc, subsystem, "")

        new_value =
          if current == "" do
            content
          else
            current <> "\n\n---\n\n" <> content
          end

        Map.put(acc, subsystem, new_value)
      end)
    end)
  end

  defp match_section_to_subsystems(section_title) do
    full_heading = "## " <> section_title

    @section_to_subsystems
    |> Enum.flat_map(fn {regex, subsystems} ->
      if Regex.match?(regex, full_heading), do: subsystems, else: []
    end)
  end
end
