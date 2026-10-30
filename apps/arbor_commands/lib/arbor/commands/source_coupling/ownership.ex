defmodule Arbor.Commands.SourceCoupling.Ownership do
  @moduledoc """
  Pure ownership index, mix.exs in-umbrella dep graph, and longest-path levels.
  """

  @app_re ~r/\Aarbor_[a-z0-9_]+\z/
  @max_module_bytes 512

  @type file_record :: %{
          required(:path) => String.t(),
          required(:blob_oid) => String.t(),
          required(:bytes) => binary(),
          optional(:app) => String.t()
        }

  @doc "Derive app name from repo-relative path."
  @spec app_of_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def app_of_path(path) when is_binary(path) do
    case Path.split(path) do
      [scope, app | _rest] when scope in ["apps", "packages"] ->
        if Regex.match?(@app_re, app), do: {:ok, app}, else: {:error, {:invalid_app, app}}

      _ ->
        {:error, {:invalid_path, path}}
    end
  end

  def app_of_path(_), do: {:error, :invalid_path}

  @doc "True if path is a tracked mix.exs for an arbor app."
  @spec mix_project_path?(String.t()) :: boolean()
  def mix_project_path?(path) when is_binary(path) do
    case Path.split(path) do
      [scope, app, "mix.exs"] when scope in ["apps", "packages"] -> Regex.match?(@app_re, app)
      _ -> false
    end
  end

  def mix_project_path?(_), do: false

  @doc "True if path is library source under apps/*/lib or packages/arbor_*/lib."
  @spec lib_source_path?(String.t()) :: boolean()
  def lib_source_path?(path) when is_binary(path) do
    parts = Path.split(path)

    case parts do
      [scope, app, "lib" | rest] when scope in ["apps", "packages"] and rest != [] ->
        Regex.match?(@app_re, app) and Enum.any?(rest, &source_filename?/1) and
          List.last(parts) |> source_filename?()

      _ ->
        false
    end
  end

  def lib_source_path?(_), do: false

  defp source_filename?(name) when is_binary(name) do
    String.ends_with?(name, ".ex") or String.ends_with?(name, ".exs")
  end

  @doc "Parse umbrella, repository-local path, and known versioned dependencies from mix.exs bytes."
  @spec in_umbrella_deps(binary(), String.t() | nil, MapSet.t(String.t())) ::
          {:ok, [String.t()]} | {:error, term()}
  def in_umbrella_deps(bytes, project_path \\ nil, known_apps \\ MapSet.new())

  def in_umbrella_deps(bytes, project_path, %MapSet{} = known_apps) when is_binary(bytes) do
    case Code.string_to_quoted(bytes, emit_warnings: false) do
      {:ok, ast} ->
        {_ast, deps} =
          Macro.prewalk(ast, [], fn
            {:{}, _metadata, [dep, _requirement, opts]} = node, acc
            when is_atom(dep) and is_list(opts) ->
              name = Atom.to_string(dep)

              if String.starts_with?(name, "arbor_") and
                   (Keyword.get(opts, :in_umbrella) == true or
                      local_path_dependency?(name, opts, project_path)) do
                {node, [name | acc]}
              else
                {node, acc}
              end

            {dep, opts} = node, acc when is_atom(dep) and is_list(opts) ->
              name = Atom.to_string(dep)

              if String.starts_with?(name, "arbor_") and
                   (Keyword.get(opts, :in_umbrella) == true or
                      local_path_dependency?(name, opts, project_path)) do
                {node, [name | acc]}
              else
                {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        published_deps =
          ast
          |> published_dependency_declarations()
          |> Enum.flat_map(fn
            {dep, requirement} when is_atom(dep) and is_binary(requirement) ->
              published_repository_dependency(dep, requirement, [], known_apps)

            {:{}, _metadata, [dep, requirement, opts]} when is_atom(dep) and is_list(opts) ->
              published_repository_dependency(dep, requirement, opts, known_apps)

            _ ->
              []
          end)

        {:ok, (deps ++ published_deps) |> Enum.uniq() |> Enum.sort()}

      {:error, reason} ->
        {:error, {:mix_parse_error, reason}}
    end
  end

  def in_umbrella_deps(_, _, _), do: {:error, :invalid_bytes}

  defp published_repository_dependency(dep, requirement, opts, known_apps) do
    name = Atom.to_string(dep)

    if is_binary(requirement) and String.starts_with?(name, "arbor_") and
         MapSet.member?(known_apps, name) and
         not Enum.any?([:path, :git, :github, :hex], &Keyword.has_key?(opts, &1)) do
      [name]
    else
      []
    end
  end

  # Published dependency tuples also resemble arbitrary keyword metadata. Only
  # inspect returned dependency lists, never every tuple in the source file.
  defp published_dependency_declarations(ast) do
    nodes = block_expressions(ast)

    functions =
      Enum.reduce(nodes, %{}, fn
        {kind, _metadata, [{name, _context, args}, body]}, acc
        when kind in [:def, :defp] and is_atom(name) and args in [nil, []] ->
          Map.update(acc, name, [Keyword.get(body, :do)], &[Keyword.get(body, :do) | &1])

        _, acc ->
          acc
      end)

    deps =
      functions
      |> Map.get(:deps, [])
      |> Enum.flat_map(&dependency_list(&1, functions, MapSet.new([:deps])))

    project_deps =
      functions
      |> Map.get(:project, [])
      |> Enum.flat_map(fn body ->
        case return_expression(body) do
          entries when is_list(entries) ->
            Enum.flat_map(entries, fn
              {:deps, value} -> dependency_list(value, functions, MapSet.new())
              _ -> []
            end)

          _ ->
            []
        end
      end)

    nested_deps =
      Enum.flat_map(nodes, fn
        {:defmodule, _metadata, [_module, body]} ->
          published_dependency_declarations(Keyword.get(body, :do))

        _ ->
          []
      end)

    deps ++ project_deps ++ nested_deps
  end

  defp dependency_list({:__block__, _metadata, expressions}, functions, seen),
    do: dependency_list(List.last(expressions), functions, seen)

  defp dependency_list(entries, functions, seen) when is_list(entries),
    do: Enum.flat_map(entries, &dependency_entry(&1, functions, seen))

  defp dependency_list({:++, _metadata, [left, right]}, functions, seen),
    do: dependency_list(left, functions, seen) ++ dependency_list(right, functions, seen)

  defp dependency_list({:|>, _metadata, [entries, _filter]}, functions, seen),
    do: dependency_list(entries, functions, seen)

  defp dependency_list({:case, _metadata, [_selector, clauses]}, functions, seen),
    do: Enum.flat_map(case_returns(clauses), &dependency_list(&1, functions, seen))

  defp dependency_list({name, _metadata, args}, functions, seen)
       when is_atom(name) and args in [nil, []] do
    if MapSet.member?(seen, name) do
      []
    else
      functions
      |> Map.get(name, [])
      |> Enum.flat_map(&dependency_list(&1, functions, MapSet.put(seen, name)))
    end
  end

  defp dependency_list(_dynamic, _functions, _seen), do: []

  # A helper in a dependency list must return one tuple, while a helper used
  # as the list itself must return a list. Do not flatten nested lists or walk
  # tuple options: those positions can contain dependency-shaped metadata.
  defp dependency_entry({dep, _requirement} = entry, _functions, _seen) when is_atom(dep),
    do: [entry]

  defp dependency_entry({:{}, _metadata, [dep, _requirement, _opts]} = entry, _functions, _seen)
       when is_atom(dep),
       do: [entry]

  defp dependency_entry({:__block__, _metadata, expressions}, functions, seen),
    do: dependency_entry(List.last(expressions), functions, seen)

  defp dependency_entry({:case, _metadata, [_selector, clauses]}, functions, seen),
    do: Enum.flat_map(case_returns(clauses), &dependency_entry(&1, functions, seen))

  defp dependency_entry({name, _metadata, args}, functions, seen)
       when is_atom(name) and args in [nil, []] do
    if MapSet.member?(seen, name) do
      []
    else
      functions
      |> Map.get(name, [])
      |> Enum.flat_map(&dependency_entry(&1, functions, MapSet.put(seen, name)))
    end
  end

  defp dependency_entry(_dynamic, _functions, _seen), do: []

  # Without evaluating operator environment, conservatively retain possible
  # branch returns. In particular, a public version dependency in the nil
  # branch remains a known-owner edge even when another branch supplies a
  # dynamic local override. Existing source admission filters each tuple.
  defp case_returns(clauses) when is_list(clauses) do
    clauses
    |> Keyword.get(:do, [])
    |> Enum.flat_map(fn
      {:->, _metadata, [_patterns, body]} -> [body]
      _other -> []
    end)
  end

  defp return_expression({:__block__, _metadata, expressions}), do: List.last(expressions)
  defp return_expression(expression), do: expression

  defp block_expressions({:__block__, _metadata, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp local_path_dependency?(name, opts, project_path) when is_binary(project_path) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) ->
        project_dir = Path.dirname(Path.join("/repository", project_path))

        case Path.split(Path.expand(path, project_dir)) do
          ["/", "repository", scope, ^name] when scope in ["apps", "packages"] -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp local_path_dependency?(_name, _opts, _project_path), do: false

  @doc """
  Build ownership index from module definition records.

  Each def: %{module, app, file, line}
  """
  @spec build_module_owners([map()]) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def build_module_owners(defs) when is_list(defs) do
    Enum.reduce_while(defs, {:ok, %{}}, fn defn, {:ok, acc} ->
      module = Map.get(defn, :module) || Map.get(defn, "module")
      app = Map.get(defn, :app) || Map.get(defn, "app")

      cond do
        not is_binary(module) or module == "" or byte_size(module) > @max_module_bytes ->
          {:halt, {:error, {:invalid_module_def, defn}}}

        not is_binary(app) ->
          {:halt, {:error, {:invalid_module_def, defn}}}

        Map.has_key?(acc, module) and Map.fetch!(acc, module) != app ->
          {:halt, {:error, {:duplicate_module_ownership, module, Map.fetch!(acc, module), app}}}

        true ->
          {:cont, {:ok, Map.put(acc, module, app)}}
      end
    end)
  end

  def build_module_owners(_), do: {:error, :invalid_defs}

  @doc "Build dep graph from %{app => [deps]}."
  @spec build_dep_graph(%{optional(String.t()) => [String.t()]}) ::
          %{optional(String.t()) => [String.t()]}
  def build_dep_graph(graph) when is_map(graph), do: graph
  def build_dep_graph(_), do: %{}

  @doc """
  Longest-path levels.

  Fails closed on cycles and on missing dependency targets (declared
  `in_umbrella` deps that have no graph node). Missing targets must never be
  silently fabricated as level-0 apps.
  """
  @spec compute_levels(%{optional(String.t()) => [String.t()]}) ::
          {:ok, %{optional(String.t()) => non_neg_integer()}} | {:error, term()}
  def compute_levels(graph) when is_map(graph) do
    with :ok <- validate_dependency_targets(graph) do
      try do
        levels =
          Enum.reduce(Map.keys(graph), %{}, fn app, cache ->
            {_lvl, cache} = level_of(app, graph, cache, MapSet.new())
            cache
          end)

        {:ok, levels}
      catch
        {:cycle, app, path} -> {:error, {:cycle, app, path}}
        {:missing_dependency_target, app} -> {:error, {:missing_dependency_target, app}}
      end
    end
  end

  def compute_levels(_), do: {:error, :invalid_graph}

  defp validate_dependency_targets(graph) when is_map(graph) do
    known = MapSet.new(Map.keys(graph))

    Enum.reduce_while(graph, :ok, fn {app, deps}, :ok ->
      deps = List.wrap(deps)

      case Enum.find(deps, fn dep -> not MapSet.member?(known, dep) end) do
        nil ->
          {:cont, :ok}

        missing when is_binary(missing) ->
          {:halt, {:error, {:missing_dependency_target, app, missing}}}

        missing ->
          {:halt, {:error, {:missing_dependency_target, app, missing}}}
      end
    end)
  end

  defp level_of(app, graph, cache, stack) do
    cond do
      Map.has_key?(cache, app) ->
        {Map.fetch!(cache, app), cache}

      MapSet.member?(stack, app) ->
        throw({:cycle, app, MapSet.to_list(MapSet.put(stack, app))})

      not Map.has_key?(graph, app) ->
        # Defensive: should be unreachable after validate_dependency_targets/1.
        throw({:missing_dependency_target, app})

      true ->
        deps = Map.fetch!(graph, app)
        next_stack = MapSet.put(stack, app)

        {lvl, cache} =
          Enum.reduce(deps, {0, cache}, fn dep, {mx, c} ->
            {dep_lvl, c} = level_of(dep, graph, c, next_stack)
            {max(mx, dep_lvl + 1), c}
          end)

        {lvl, Map.put(cache, app, lvl)}
    end
  end

  @doc "level_downward | level_same | level_upward | level_unknown"
  @spec level_direction(String.t(), String.t(), map()) :: String.t()
  def level_direction(from_app, to_app, levels)
      when is_binary(from_app) and is_binary(to_app) and is_map(levels) do
    case {Map.fetch(levels, from_app), Map.fetch(levels, to_app)} do
      {{:ok, lf}, {:ok, lt}} when lf > lt -> "level_downward"
      {{:ok, lf}, {:ok, lt}} when lf < lt -> "level_upward"
      {{:ok, lf}, {:ok, lt}} when lf == lt -> "level_same"
      _ -> "level_unknown"
    end
  end

  def level_direction(_, _, _), do: "level_unknown"
end
