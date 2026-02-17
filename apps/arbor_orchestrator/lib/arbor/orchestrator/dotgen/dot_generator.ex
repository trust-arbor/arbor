defmodule Arbor.Orchestrator.Dotgen.DotGenerator do
  @moduledoc """
  Generates .dot pipeline files from analyzed source metadata.

  Takes the output of `SourceAnalyzer` and produces a complete, valid .dot
  pipeline file. The generated .dot file is self-contained — its implementation
  prompts include ALL specification details needed to reproduce the source files
  from scratch.
  """

  alias Arbor.Orchestrator.Dotgen.SourceAnalyzer

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Generates a complete .dot pipeline string.

  Parameters:
    - `subsystem_name` — e.g. "graph", "engine", "context"
    - `file_infos` — list of analyzed file metadata maps from `SourceAnalyzer`
    - `opts` — keyword options:
      - `:goal` — graph goal string (default: auto-generated)
      - `:max_files_per_node` — max files per implementation node (default: 4)
      - `:include_tests` — whether to add a write_tests node (default: true)
  """
  @spec generate(String.t(), [SourceAnalyzer.file_info()], keyword()) :: String.t()
  def generate(subsystem_name, file_infos, opts \\ []) do
    goal = Keyword.get(opts, :goal, default_goal(subsystem_name))
    max_per_node = Keyword.get(opts, :max_files_per_node, 4)
    include_tests = Keyword.get(opts, :include_tests, true)

    groups = SourceAnalyzer.group_files(file_infos, max_per_node)

    impl_nodes = build_impl_nodes(groups)
    test_node = if include_tests, do: build_test_node(file_infos), else: nil
    tool_nodes = build_tool_nodes()
    quality_node = build_quality_node(impl_nodes)

    dot =
      [
        "digraph implement_#{subsystem_name} {",
        "  graph [goal=#{quote_dot(goal)}]",
        "",
        "  start [shape=Mdiamond]",
        "",
        format_impl_section(impl_nodes),
        format_test_section(test_node),
        format_tool_section(tool_nodes),
        format_quality_section(quality_node),
        "  done [shape=Msquare]",
        "",
        format_edges(impl_nodes, test_node, quality_node),
        "}"
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    dot <> "\n"
  end

  @doc """
  Converts a single file_info map into a detailed natural language specification
  suitable for an LLM implementation prompt.

  The output includes file path, module name, moduledoc, struct fields with
  exact defaults, type definitions, public/private function signatures, module
  attributes, behaviour declarations, and implementation details.
  """
  @spec format_file_prompt(SourceAnalyzer.file_info()) :: String.t()
  def format_file_prompt(file_info) do
    sections =
      [
        format_header(file_info),
        format_moduledoc_section(file_info),
        format_behaviours_section(file_info),
        format_uses_section(file_info),
        format_callbacks_section(file_info),
        format_struct_section(file_info),
        format_types_section(file_info),
        format_attributes_section(file_info),
        format_public_functions_section(file_info),
        format_private_functions_section(file_info),
        format_test_examples_section(file_info)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  @doc """
  Combines multiple file_info prompts into a single implementation node prompt.

  Prefixes with "Create N Elixir modules:" and suffixes with an instruction
  to output only the complete source code for all files.
  """
  @spec format_group_prompt([SourceAnalyzer.file_info()]) :: String.t()
  def format_group_prompt(file_infos) do
    n = length(file_infos)

    file_prompts =
      file_infos
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {info, idx} ->
        "FILE #{idx}: #{format_file_prompt(info)}"
      end)

    prefix =
      if n == 1,
        do: "Create 1 Elixir module:",
        else: "Create #{n} Elixir modules:"

    suffix =
      "Write each file to disk using the Write tool. " <>
        "Create all #{n} files with the COMPLETE Elixir source code. " <>
        "Do NOT just output the code as text — actually write the files."

    "#{prefix}\n\n#{file_prompts}\n\n#{suffix}"
  end

  # ── File Prompt Formatting ──────────────────────────────────────────

  defp format_header(%{path: path, module: module}) do
    "#{path}\nModule: #{module}"
  end

  defp format_moduledoc_section(%{moduledoc: nil}), do: nil
  defp format_moduledoc_section(%{moduledoc: ""}), do: nil

  defp format_moduledoc_section(%{moduledoc: doc}) do
    "@moduledoc #{inspect(doc)}"
  end

  defp format_behaviours_section(%{behaviours: []}), do: nil

  defp format_behaviours_section(%{behaviours: behaviours}) do
    lines = Enum.map(behaviours, fn b -> "@behaviour #{b}" end)
    Enum.join(lines, "\n")
  end

  defp format_uses_section(%{uses: []}), do: nil

  defp format_uses_section(%{uses: uses}) do
    lines = Enum.map(uses, fn u -> "use #{u}" end)
    Enum.join(lines, "\n")
  end

  defp format_callbacks_section(%{callbacks: []}), do: nil

  defp format_callbacks_section(%{callbacks: callbacks}) do
    header = "Callbacks:"
    lines = Enum.map(callbacks, fn cb -> "- #{cb}" end)
    Enum.join([header | lines], "\n")
  end

  defp format_struct_section(%{struct_fields: []}), do: nil

  defp format_struct_section(%{struct_fields: fields}) do
    "Struct fields with defaults:\n" <> format_struct_fields(fields)
  end

  defp format_types_section(%{types: []}), do: nil

  defp format_types_section(%{types: types}) do
    Enum.join(types, "\n")
  end

  defp format_attributes_section(%{module_attributes: []}), do: nil

  defp format_attributes_section(%{module_attributes: attrs}) do
    header = "Module attributes:"
    lines = Enum.map(attrs, fn %{name: name, value: value} -> "- @#{name} #{value}" end)
    Enum.join([header | lines], "\n")
  end

  defp format_public_functions_section(%{public_functions: []}), do: nil

  defp format_public_functions_section(%{public_functions: funcs}) do
    header = "Public functions:"
    lines = Enum.map(funcs, &format_function/1)
    Enum.join([header | lines], "\n")
  end

  defp format_private_functions_section(%{private_functions: []}), do: nil

  defp format_private_functions_section(%{private_functions: funcs}) do
    header = "Private functions:"

    lines =
      Enum.map(funcs, fn %{name: name, arity: arity, body_summary: summary} = func ->
        args = if arity == 0, do: "()", else: "/#{arity}"
        base = "- #{name}#{args} — #{summary}"
        clauses_str = format_clauses(Map.get(func, :clauses, []))
        branches_str = format_branches(Map.get(func, :case_branches, []))
        parts = [base, clauses_str, branches_str] |> Enum.reject(&is_nil/1)
        Enum.join(parts, "")
      end)

    Enum.join([header | lines], "\n")
  end

  defp format_test_examples_section(%{test_examples: nil}), do: nil

  defp format_test_examples_section(%{test_examples: %{descriptions: [], assertions: []}}),
    do: nil

  defp format_test_examples_section(%{test_examples: examples}) do
    sections = []

    sections =
      if examples.descriptions != [] do
        desc_lines = Enum.map(Enum.take(examples.descriptions, 30), fn d -> "- #{d}" end)
        sections ++ ["Expected test behaviors:\n" <> Enum.join(desc_lines, "\n")]
      else
        sections
      end

    sections =
      if examples.assertions != [] do
        assert_lines = Enum.map(Enum.take(examples.assertions, 30), fn a -> "- #{a}" end)
        sections ++ ["Key assertions from tests:\n" <> Enum.join(assert_lines, "\n")]
      else
        sections
      end

    if sections != [], do: Enum.join(sections, "\n\n"), else: nil
  end

  defp format_test_examples_section(_), do: nil

  # ── Private Helpers ─────────────────────────────────────────────────

  defp format_struct_fields(fields) do
    Enum.map_join(fields, ", \n", fn {name, default} -> "  #{name}: #{default}" end)
  end

  defp format_function(
         %{name: name, arity: arity, spec: spec, doc: doc, body_summary: summary} = func
       ) do
    args = if arity == 0, do: "()", else: "/#{arity}"
    base = "- #{name}#{args}"

    parts =
      [
        if(spec, do: "\n    #{spec}"),
        if(doc, do: "\n    #{doc}"),
        if(summary != "...", do: " — #{summary}"),
        format_clauses(Map.get(func, :clauses, [])),
        format_branches(Map.get(func, :case_branches, []))
      ]
      |> Enum.reject(&is_nil/1)

    base <> Enum.join(parts, "")
  end

  defp format_clauses([]), do: nil
  defp format_clauses([_single]), do: nil

  defp format_clauses(clauses) do
    lines =
      clauses
      |> Enum.with_index(1)
      |> Enum.map(fn {clause, idx} ->
        patterns = Enum.join(clause.patterns, ", ")
        guard = if clause.guard, do: " when #{clause.guard}", else: ""
        summary = if clause.body_summary != "...", do: " — #{clause.body_summary}", else: ""
        "      #{idx}. (#{patterns})#{guard}#{summary}"
      end)

    "\n    Clauses:\n" <> Enum.join(lines, "\n")
  end

  defp format_branches([]), do: nil

  defp format_branches(branches) do
    lines = Enum.map(branches, fn b -> "      - #{b}" end)
    "\n    Branches:\n" <> Enum.join(lines, "\n")
  end

  # ── DOT Generation Helpers ──────────────────────────────────────────

  defp default_goal(subsystem_name) do
    pretty = subsystem_name |> String.replace("_", " ") |> String.capitalize()
    "Implement the #{pretty} subsystem"
  end

  defp build_impl_nodes(groups) do
    groups
    |> Enum.with_index(1)
    |> Enum.map(fn {group, idx} ->
      prompt = format_group_prompt(group)
      node_id = "impl_#{idx}"

      comment =
        Enum.map_join(group, ", ", fn %{module: m} -> m end)

      {node_id, prompt, comment}
    end)
  end

  defp build_test_node(file_infos) do
    modules =
      Enum.map_join(file_infos, ", ", fn %{module: m} -> m end)

    paths =
      file_infos
      |> Enum.map(fn %{path: p} -> p end)

    test_dir = common_test_dir(paths)

    prompt =
      "Write comprehensive ExUnit tests for the following modules: #{modules}.\n\n" <>
        "Create test file(s) under #{test_dir}.\n" <>
        "use ExUnit.Case, async: true\n\n" <>
        "Cover all public functions, edge cases, and error paths.\n" <>
        "Write the complete test file(s) to disk using the Write tool."

    {"write_tests", prompt}
  end

  defp build_tool_nodes do
    [
      {"compile", "mix compile --warnings-as-errors"},
      {"run_tests", "mix test"}
    ]
  end

  defp build_quality_node(impl_nodes) do
    {first_id, _, _} = List.first(impl_nodes)
    {"quality", "Compilation clean and all tests pass?", first_id}
  end

  defp common_test_dir(paths) do
    case paths do
      [] ->
        "test/"

      [first | _] ->
        first
        |> String.replace_leading("lib/", "test/")
        |> Path.dirname()
        |> Kernel.<>("/")
    end
  end

  # ── DOT Formatting ──────────────────────────────────────────────────

  defp format_impl_section(impl_nodes) do
    impl_nodes
    |> Enum.flat_map(fn {node_id, prompt, comment} ->
      [
        "  // ── #{comment} ──",
        "  #{node_id} [shape=box, prompt=#{quote_dot(prompt)}]",
        ""
      ]
    end)
  end

  defp format_test_section(nil), do: []

  defp format_test_section({node_id, prompt}) do
    [
      "  // ── Tests ──",
      "  #{node_id} [shape=box, prompt=#{quote_dot(prompt)}]",
      ""
    ]
  end

  defp format_tool_section(tool_nodes) do
    lines =
      Enum.map(tool_nodes, fn {node_id, command} ->
        "  #{node_id} [shape=parallelogram, tool_command=#{quote_dot(command)}]"
      end)

    ["  // ── Tool nodes ──" | lines] ++ [""]
  end

  defp format_quality_section({node_id, prompt, retry_target}) do
    [
      "  // ── Quality gate ──",
      "  #{node_id} [shape=diamond, prompt=#{quote_dot(prompt)}, goal_gate=true, retry_target=#{quote_dot(retry_target)}]",
      ""
    ]
  end

  defp format_edges(impl_nodes, test_node, {quality_id, _, _}) do
    impl_ids = Enum.map(impl_nodes, fn {id, _, _} -> id end)
    first_impl = List.first(impl_ids)

    # Build the sequential chain
    chain_nodes =
      ["start"] ++
        impl_ids ++
        if(test_node, do: [elem(test_node, 0)], else: []) ++
        ["compile", "run_tests", quality_id]

    chain_edges =
      chain_nodes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> "  #{from} -> #{to}" end)

    success_edge = "  #{quality_id} -> done [condition=\"outcome=success\"]"
    fail_edge = "  #{quality_id} -> #{first_impl} [condition=\"outcome=fail\"]"

    ["  // ── Edges ──"] ++ chain_edges ++ [success_edge, fail_edge]
  end

  # ── DOT String Escaping ─────────────────────────────────────────────

  defp escape_dot_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp quote_dot(str) do
    "\"" <> escape_dot_string(str) <> "\""
  end
end
