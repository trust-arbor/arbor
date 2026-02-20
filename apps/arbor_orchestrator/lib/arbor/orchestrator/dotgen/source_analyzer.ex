defmodule Arbor.Orchestrator.Dotgen.SourceAnalyzer do
  @moduledoc """
  Analyzes Elixir source files and extracts structured metadata.

  Reads .ex source files and returns comprehensive metadata maps that contain
  enough information for an LLM to reproduce the source file without access
  to the original. Used by the dotgen pipeline to produce self-contained
  .dot pipeline prompts.
  """

  @type clause_info :: %{
          patterns: [String.t()],
          guard: String.t() | nil,
          body_summary: String.t()
        }

  @type function_info :: %{
          name: atom(),
          arity: non_neg_integer(),
          spec: String.t() | nil,
          doc: String.t() | nil,
          body_summary: String.t(),
          clauses: [clause_info()],
          case_branches: [String.t()]
        }

  @type file_info :: %{
          path: String.t(),
          module: String.t(),
          moduledoc: String.t() | nil,
          behaviours: [String.t()],
          callbacks: [String.t()],
          struct_fields: [{atom(), String.t()}],
          types: [String.t()],
          public_functions: [function_info()],
          private_functions: [%{name: atom(), arity: non_neg_integer(), body_summary: String.t()}],
          module_attributes: [%{name: atom(), value: String.t()}],
          aliases: [String.t()],
          uses: [String.t()],
          line_count: non_neg_integer(),
          test_examples: %{descriptions: [String.t()], assertions: [String.t()]} | nil
        }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Reads an .ex file and returns a map of extracted metadata.

  Parses the file's AST to extract module name, documentation, behaviours,
  callbacks, struct definitions, type specs, functions, and module attributes.
  """
  @spec analyze_file(String.t()) :: {:ok, file_info()} | {:error, String.t()}
  def analyze_file(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- parse_source(source) do
      line_count = source |> String.split("\n") |> length()

      info =
        %{
          path: path,
          module: nil,
          moduledoc: nil,
          behaviours: [],
          callbacks: [],
          struct_fields: [],
          types: [],
          public_functions: [],
          private_functions: [],
          module_attributes: [],
          aliases: [],
          uses: [],
          line_count: line_count
        }
        |> extract_from_ast(ast, source)

      {:ok, info}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Recursively finds all .ex files in a directory and analyzes each.

  Options:
    - `:exclude` — list of glob patterns to skip (e.g., `["*_test.exs"]`)
    - `:include` — only include files matching these patterns
  """
  @spec analyze_directory(String.t(), keyword()) :: {:ok, [file_info()]} | {:error, String.t()}
  def analyze_directory(dir_path, opts \\ []) do
    case File.ls(dir_path) do
      {:ok, _} ->
        files = find_ex_files(dir_path, opts)

        results =
          Enum.reduce_while(files, {:ok, []}, fn file, {:ok, infos} ->
            case analyze_file(file) do
              {:ok, info} -> {:cont, {:ok, [info | infos]}}
              {:error, reason} -> {:halt, {:error, "Failed to analyze #{file}: #{reason}"}}
            end
          end)

        case results do
          {:ok, infos} -> {:ok, Enum.reverse(infos)}
          error -> error
        end

      {:error, reason} ->
        {:error, "Cannot read directory #{dir_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Groups analyzed files into implementation-node chunks.

  Groups by directory proximity, keeping files in the same subdirectory
  together when possible. Each group has at most `max_per_group` files.
  """
  @spec group_files([file_info()], pos_integer()) :: [[file_info()]]
  def group_files(file_infos, max_per_group \\ 4) do
    file_infos
    |> Enum.group_by(&parent_dir/1)
    |> Enum.sort_by(fn {dir, _files} -> dir end)
    |> Enum.flat_map(fn {_dir, files} ->
      files
      |> sort_by_dependency()
      |> Enum.chunk_every(max_per_group)
    end)
  end

  @doc """
  Analyzes a source file and enriches it with test-derived examples
  if a companion test file exists.

  Same as `analyze_file/1` but adds `:test_examples` to the result when
  a matching test file is found at the conventional test path.
  """
  @spec analyze_with_tests(String.t()) :: {:ok, file_info()} | {:error, String.t()}
  def analyze_with_tests(path) do
    with {:ok, info} <- analyze_file(path) do
      test_examples =
        case find_companion_test(path) do
          nil ->
            nil

          test_path ->
            case extract_test_examples(test_path) do
              {:ok, examples} -> examples
              {:error, _} -> nil
            end
        end

      {:ok, Map.put(info, :test_examples, test_examples)}
    end
  end

  @doc """
  Extract test descriptions and key assertions from a test file.

  Returns `{:ok, %{descriptions: [...], assertions: [...]}}` where
  descriptions are test block names and assertions are assert/refute lines.
  """
  @spec extract_test_examples(String.t()) ::
          {:ok, %{descriptions: [String.t()], assertions: [String.t()]}} | {:error, String.t()}
  def extract_test_examples(test_path) do
    case File.read(test_path) do
      {:ok, source} ->
        descriptions =
          Regex.scan(~r/test\s+"([^"]+)"/, source)
          |> Enum.map(fn [_, desc] -> desc end)
          |> Enum.uniq()

        assertions =
          source
          |> String.split("\n")
          |> Enum.filter(fn line ->
            trimmed = String.trim(line)

            (String.starts_with?(trimmed, "assert ") or
               String.starts_with?(trimmed, "refute ") or
               String.starts_with?(trimmed, "assert_raise ") or
               String.starts_with?(trimmed, "assert_receive ")) and
              String.length(trimmed) < 200
          end)
          |> Enum.map(&String.trim/1)
          |> Enum.uniq()
          |> Enum.take(50)

        {:ok, %{descriptions: descriptions, assertions: assertions}}

      {:error, reason} ->
        {:error, "Cannot read test file #{test_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Find the companion test file for a source file.

  Transforms `lib/foo/bar.ex` to `test/foo/bar_test.exs`.
  """
  @spec find_companion_test(String.t()) :: String.t() | nil
  def find_companion_test(source_path) do
    test_path =
      source_path
      |> String.replace_leading("lib/", "test/")
      |> String.replace_trailing(".ex", "_test.exs")

    if File.exists?(test_path), do: test_path, else: nil
  end

  # ── Source Parsing ──────────────────────────────────────────────────

  defp parse_source(source) do
    ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)
    {:ok, ast}
  rescue
    e in [SyntaxError, TokenMissingError, CompileError, MismatchedDelimiterError] ->
      {:error, "Parse error: #{Exception.message(e)}"}
  end

  # ── AST Extraction ─────────────────────────────────────────────────

  defp extract_from_ast(info, {:defmodule, _meta, [alias_ast, [do: body]]}, source) do
    module_name = module_name_from_ast(alias_ast)

    info
    |> Map.put(:module, module_name)
    |> extract_body(body, source)
  end

  defp extract_from_ast(info, {:__block__, _meta, exprs}, source) do
    # Top-level file may have multiple expressions; find the defmodule
    Enum.reduce(exprs, info, fn expr, acc ->
      case expr do
        {:defmodule, _meta, _args} -> extract_from_ast(acc, expr, source)
        _ -> acc
      end
    end)
  end

  defp extract_from_ast(info, _ast, _source), do: info

  defp extract_body(info, {:__block__, _meta, statements}, source) do
    extract_statements(info, statements, source)
  end

  defp extract_body(info, statement, source) when is_tuple(statement) do
    extract_statements(info, [statement], source)
  end

  defp extract_body(info, _other, _source), do: info

  defp extract_statements(info, statements, source) do
    {info, _pending_doc, _pending_spec} =
      Enum.reduce(statements, {info, nil, nil}, fn stmt, {acc, pending_doc, pending_spec} ->
        extract_statement(stmt, acc, pending_doc, pending_spec, source)
      end)

    info
  end

  defp extract_statement(
         {:@, _meta, [{:moduledoc, _meta2, [doc]}]},
         acc,
         pending_doc,
         pending_spec,
         _source
       ) do
    {Map.put(acc, :moduledoc, extract_doc_value(doc)), pending_doc, pending_spec}
  end

  defp extract_statement(
         {:@, _meta, [{:doc, _meta2, [false]}]},
         acc,
         _pending_doc,
         pending_spec,
         _source
       ) do
    {acc, false, pending_spec}
  end

  defp extract_statement(
         {:@, _meta, [{:doc, _meta2, [doc]}]},
         acc,
         _pending_doc,
         pending_spec,
         _source
       ) do
    {acc, extract_doc_value(doc), pending_spec}
  end

  defp extract_statement(
         {:@, _meta, [{:spec, _meta2, [spec_ast]}]},
         acc,
         pending_doc,
         _pending_spec,
         source
       ) do
    spec_str = format_spec(spec_ast, source)
    {acc, pending_doc, spec_str}
  end

  defp extract_statement(
         {:@, _meta, [{:behaviour, _meta2, [mod_ast]}]},
         acc,
         pending_doc,
         pending_spec,
         _source
       ) do
    behaviour = module_name_from_ast(mod_ast)
    {Map.update!(acc, :behaviours, &(&1 ++ [behaviour])), pending_doc, pending_spec}
  end

  defp extract_statement(
         {:@, _meta, [{:callback, _meta2, [callback_ast]}]},
         acc,
         pending_doc,
         pending_spec,
         source
       ) do
    callback_str = format_callback(callback_ast, source)
    {Map.update!(acc, :callbacks, &(&1 ++ [callback_str])), pending_doc, pending_spec}
  end

  defp extract_statement(
         {:@, _meta, [{type_kind, _meta2, [type_ast]}]},
         acc,
         pending_doc,
         pending_spec,
         source
       )
       when type_kind in [:type, :typep, :opaque] do
    type_str = format_type(type_kind, type_ast, source)
    {Map.update!(acc, :types, &(&1 ++ [type_str])), pending_doc, pending_spec}
  end

  defp extract_statement(
         {:@, _meta, [{:impl, _meta2, _args}]},
         acc,
         pending_doc,
         pending_spec,
         _source
       ) do
    {acc, pending_doc, pending_spec}
  end

  @skipped_attrs ~w(moduledoc doc spec behaviour callback type typep opaque impl derive enforce_keys before_compile after_compile compile on_definition external_resource)a

  defp extract_statement(
         {:@, _meta, [{attr_name, _meta2, [value]}]},
         acc,
         pending_doc,
         pending_spec,
         _source
       )
       when attr_name not in @skipped_attrs do
    attr = %{name: attr_name, value: format_value(value)}
    {Map.update!(acc, :module_attributes, &(&1 ++ [attr])), pending_doc, pending_spec}
  end

  defp extract_statement({:defstruct, _meta, [fields]}, acc, pending_doc, pending_spec, _source) do
    struct_fields = extract_struct_fields(fields)
    {Map.put(acc, :struct_fields, struct_fields), pending_doc, pending_spec}
  end

  defp extract_statement({:def, meta, _args} = def_ast, acc, pending_doc, pending_spec, source) do
    clause = extract_clause_info(def_ast, source)
    {name, arity} = function_head(def_ast)

    acc =
      merge_or_add_function(
        acc,
        :public_functions,
        name,
        arity,
        clause,
        def_ast,
        source,
        fn -> extract_function(def_ast, meta, pending_doc, pending_spec, source) end
      )

    {acc, nil, nil}
  end

  defp extract_statement({:defp, meta, _args} = def_ast, acc, _pending_doc, _pending_spec, source) do
    clause = extract_clause_info(def_ast, source)
    {name, arity} = function_head(def_ast)

    acc =
      merge_or_add_function(
        acc,
        :private_functions,
        name,
        arity,
        clause,
        def_ast,
        source,
        fn -> extract_private_function(def_ast, meta, source) end
      )

    {acc, nil, nil}
  end

  defp extract_statement(
         {:alias, _meta, [alias_ast | _rest]},
         acc,
         pending_doc,
         pending_spec,
         _source
       ) do
    alias_str = module_name_from_ast(alias_ast)
    {Map.update!(acc, :aliases, &(&1 ++ [alias_str])), pending_doc, pending_spec}
  end

  defp extract_statement(
         {:use, _meta, [mod_ast | _rest]},
         acc,
         pending_doc,
         pending_spec,
         _source
       ) do
    use_str = module_name_from_ast(mod_ast)
    {Map.update!(acc, :uses, &(&1 ++ [use_str])), pending_doc, pending_spec}
  end

  defp extract_statement(_other, acc, pending_doc, pending_spec, _source) do
    {acc, pending_doc, pending_spec}
  end

  defp merge_or_add_function(acc, field, name, arity, clause, def_ast, _source, new_func_fn) do
    existing = Map.get(acc, field)

    if Enum.any?(existing, fn f -> f.name == name and f.arity == arity end) do
      new_branches = extract_case_branches(def_ast)
      updated = merge_clause_into(existing, name, arity, clause, new_branches)
      Map.put(acc, field, updated)
    else
      func = new_func_fn.()

      func =
        Map.merge(func, %{
          clauses: [clause],
          case_branches: extract_case_branches(def_ast)
        })

      Map.update!(acc, field, &(&1 ++ [func]))
    end
  end

  defp merge_clause_into(functions, name, arity, clause, new_branches) do
    Enum.map(functions, fn f ->
      if f.name == name and f.arity == arity do
        f
        |> Map.update!(:clauses, &(&1 ++ [clause]))
        |> Map.update(:case_branches, new_branches, &(&1 ++ new_branches))
      else
        f
      end
    end)
  end

  # ── Module Name Extraction ─────────────────────────────────────────

  defp module_name_from_ast({:__aliases__, _meta, parts}) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name_from_ast(atom) when is_atom(atom), do: to_string(atom)
  defp module_name_from_ast(other), do: Macro.to_string(other)

  # ── Doc Value Extraction ───────────────────────────────────────────

  defp extract_doc_value(value) when is_binary(value), do: value
  defp extract_doc_value(false), do: nil
  defp extract_doc_value({:sigil_S, _meta, _args} = ast), do: Macro.to_string(ast)
  defp extract_doc_value(_other), do: nil

  # ── Function Extraction ────────────────────────────────────────────

  defp extract_function(def_ast, _meta, pending_doc, pending_spec, source) do
    {name, arity} = function_head(def_ast)

    doc =
      case pending_doc do
        false -> nil
        other -> other
      end

    %{
      name: name,
      arity: arity,
      spec: pending_spec,
      doc: doc,
      body_summary: body_summary(def_ast, source)
    }
  end

  defp extract_private_function(def_ast, _meta, source) do
    {name, arity} = function_head(def_ast)

    %{
      name: name,
      arity: arity,
      body_summary: body_summary(def_ast, source)
    }
  end

  defp function_head({_kind, _meta, [{:when, _m, [head | _guards]}, _body]}) do
    function_name_arity(head)
  end

  defp function_head({_kind, _meta, [head, _body]}) do
    function_name_arity(head)
  end

  defp function_head({_kind, _meta, [head]}) do
    function_name_arity(head)
  end

  defp function_name_arity({name, _meta, nil}) when is_atom(name), do: {name, 0}

  defp function_name_arity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp function_name_arity(_other), do: {:unknown, 0}

  # ── Body Summary ───────────────────────────────────────────────────

  defp body_summary({_kind, _meta, [{:when, _m, [_head | _guards]}, [do: body]]}, _source) do
    summarize_body(body)
  end

  defp body_summary({_kind, _meta, [_head, [do: body]]}, _source) do
    summarize_body(body)
  end

  defp body_summary(_def_ast, _source), do: "..."

  defp summarize_body({:__block__, _meta, [first | _rest]}) do
    summary = Macro.to_string(first)
    truncate(summary, 300)
  end

  defp summarize_body(expr) do
    summary = Macro.to_string(expr)
    truncate(summary, 300)
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  # ── Clause Pattern Extraction ─────────────────────────────────────

  defp extract_clause_info(def_ast, source) do
    {patterns, guard} = extract_clause_head(def_ast)

    %{
      patterns: patterns,
      guard: guard,
      body_summary: body_summary(def_ast, source)
    }
  end

  defp extract_clause_head({_kind, _meta, [{:when, _m, [head | guards]}, _body]}) do
    patterns = extract_arg_patterns(head)
    guard_str = Enum.map_join(guards, " and ", &Macro.to_string/1)
    {patterns, guard_str}
  end

  defp extract_clause_head({_kind, _meta, [head, _body]}) do
    {extract_arg_patterns(head), nil}
  end

  defp extract_clause_head({_kind, _meta, [head]}) do
    {extract_arg_patterns(head), nil}
  end

  defp extract_clause_head(_), do: {[], nil}

  defp extract_arg_patterns({_name, _meta, nil}), do: []

  defp extract_arg_patterns({_name, _meta, args}) when is_list(args) do
    Enum.map(args, fn arg -> Macro.to_string(arg) |> truncate(80) end)
  end

  defp extract_arg_patterns(_), do: []

  # ── Case Branch Extraction ──────────────────────────────────────

  defp extract_case_branches({_kind, _meta, [{:when, _m, [_head | _guards]}, [do: body]]}) do
    collect_top_branches(body)
  end

  defp extract_case_branches({_kind, _meta, [_head, [do: body]]}) do
    collect_top_branches(body)
  end

  defp extract_case_branches(_), do: []

  defp collect_top_branches({:__block__, _meta, exprs}) do
    Enum.flat_map(exprs, &collect_single_branch/1)
  end

  defp collect_top_branches(expr), do: collect_single_branch(expr)

  defp collect_single_branch({:case, _meta, [expr, [do: clauses]]}) do
    expr_str = Macro.to_string(expr) |> truncate(60)

    patterns =
      Enum.map(clauses, fn {:->, _m, [pats, _body]} ->
        Enum.map_join(pats, ", ", &Macro.to_string/1) |> truncate(40)
      end)

    ["case #{expr_str} -> #{Enum.join(patterns, " | ")}"]
  end

  defp collect_single_branch({:cond, _meta, [[do: clauses]]}) do
    conditions =
      Enum.map(clauses, fn {:->, _m, [[condition], _body]} ->
        Macro.to_string(condition) |> truncate(40)
      end)

    ["cond -> #{Enum.join(conditions, " | ")}"]
  end

  defp collect_single_branch({:if, _meta, [condition | _]}) do
    ["if #{Macro.to_string(condition) |> truncate(60)}"]
  end

  defp collect_single_branch({:with, _meta, clauses_and_body}) do
    patterns =
      clauses_and_body
      |> Enum.take_while(fn
        {:<-, _, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:<-, _, [pattern, expr]} ->
        "#{Macro.to_string(pattern) |> truncate(30)} <- #{Macro.to_string(expr) |> truncate(30)}"
      end)

    if patterns != [], do: ["with #{Enum.join(patterns, ", ")}"], else: []
  end

  defp collect_single_branch(_), do: []

  # ── Struct Fields ──────────────────────────────────────────────────

  defp extract_struct_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      {name, default} when is_atom(name) ->
        {name, Macro.to_string(default)}

      name when is_atom(name) ->
        {name, "nil"}

      other ->
        {:unknown, Macro.to_string(other)}
    end)
  end

  defp extract_struct_fields(_other), do: []

  # ── Spec / Type / Callback Formatting ──────────────────────────────

  defp format_spec(spec_ast, _source) do
    "@spec " <> Macro.to_string(spec_ast)
  rescue
    _ -> nil
  end

  defp format_callback(callback_ast, _source) do
    "@callback " <> Macro.to_string(callback_ast)
  rescue
    _ -> nil
  end

  defp format_type(kind, type_ast, _source) do
    "@#{kind} " <> Macro.to_string(type_ast)
  rescue
    _ -> nil
  end

  # ── Value Formatting ───────────────────────────────────────────────

  defp format_value(value) do
    Macro.to_string(value)
  rescue
    _ -> inspect(value)
  end

  # ── File Discovery ─────────────────────────────────────────────────

  defp find_ex_files(dir_path, opts) do
    exclude = Keyword.get(opts, :exclude, [])
    include = Keyword.get(opts, :include, [])

    Path.wildcard(Path.join(dir_path, "**/*.ex"))
    |> Enum.filter(fn path ->
      filename = Path.basename(path)

      not excluded?(filename, exclude) and
        (include == [] or included?(filename, include))
    end)
    |> Enum.sort()
  end

  defp excluded?(filename, patterns) do
    Enum.any?(patterns, fn pattern ->
      match_pattern?(filename, pattern)
    end)
  end

  defp included?(filename, patterns) do
    Enum.any?(patterns, fn pattern ->
      match_pattern?(filename, pattern)
    end)
  end

  defp match_pattern?(filename, pattern) do
    # Convert glob-like patterns to regex
    regex_str =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")

    # Source analyzer: compiles glob-to-regex for file filtering
    # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
    case Regex.compile("^" <> regex_str <> "$") do
      {:ok, regex} -> Regex.match?(regex, filename)
      _ -> false
    end
  end

  # ── File Grouping ──────────────────────────────────────────────────

  defp parent_dir(%{path: path}) do
    Path.dirname(path)
  end

  defp sort_by_dependency(files) do
    # Sort files within a directory by dependency order:
    # 1. Behaviours/protocols first (they define contracts)
    # 2. Structs/types next (they define data)
    # 3. Implementation modules last
    Enum.sort_by(files, fn file ->
      cond do
        file.callbacks != [] -> 0
        file.struct_fields != [] and file.public_functions == [] -> 1
        file.struct_fields != [] -> 2
        true -> 3
      end
    end)
  end
end
