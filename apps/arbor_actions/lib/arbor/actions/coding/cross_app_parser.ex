defmodule Arbor.Actions.Coding.CrossApp.Parser do
  @moduledoc """
  Static AST parser for umbrella `apps/*/mix.exs` dependency discovery.

  Never evaluates or compiles candidate source. Uses `Code.string_to_quoted/2`
  with `existing_atoms_only` and a `static_atoms_encoder` that returns non-atoms
  so hostile source cannot grow the atom table.

  Note: when `static_atoms_encoder` is set, Elixir rewrites *all* static atom
  literals in the AST (including `defmodule`/`def`/`app`). The matcher therefore
  treats both bare atoms and `{:__non_atom__, name}` forms as identifiers.
  """

  @max_file_bytes 64_000
  @max_total_bytes 2_000_000
  @max_files 256
  @max_identifier_bytes 64

  @type app_def :: Arbor.Actions.Coding.CrossApp.Core.app_def()

  @doc """
  Parse a single mix.exs source string into `{dir, app, deps}` metadata.

  `dir` is the apps/<dir> directory name supplied by the caller and must match
  the declared `app:` atom string.
  """
  @spec parse_mix_exs(String.t(), String.t()) :: {:ok, app_def()} | {:error, term()}
  def parse_mix_exs(source, dir)
      when is_binary(source) and is_binary(dir) do
    with :ok <- validate_dir(dir),
         :ok <- validate_source_size(source),
         {:ok, ast} <- safe_quote(source),
         {:ok, app} <- extract_app(ast),
         {:ok, deps} <- extract_in_umbrella_deps(ast) do
      if app == dir do
        {:ok, %{dir: dir, app: app, deps: Enum.sort(Enum.uniq(deps))}}
      else
        {:error, {:app_dir_name_mismatch, dir, app}}
      end
    end
  end

  def parse_mix_exs(_, _), do: {:error, :invalid_parse_input}

  @doc """
  Parse many `{dir, source}` pairs with aggregate byte/file bounds.
  """
  @spec parse_many([{String.t(), String.t()}]) :: {:ok, [app_def()]} | {:error, term()}
  def parse_many(entries) when is_list(entries) do
    with :ok <- validate_entry_count(entries),
         :ok <- validate_total_bytes(entries) do
      Enum.reduce_while(entries, {:ok, []}, fn {dir, source}, {:ok, acc} ->
        case parse_mix_exs(source, dir) do
          {:ok, app_def} -> {:cont, {:ok, [app_def | acc]}}
          {:error, reason} -> {:halt, {:error, {:parse_failed, dir, reason}}}
        end
      end)
      |> case do
        {:ok, defs} -> {:ok, Enum.reverse(defs)}
        {:error, _} = error -> error
      end
    end
  end

  def parse_many(_), do: {:error, :invalid_parse_input}

  defp validate_dir(dir) do
    if valid_identifier?(dir), do: :ok, else: {:error, :invalid_app_dir}
  end

  defp validate_source_size(source) do
    if byte_size(source) <= @max_file_bytes, do: :ok, else: {:error, :mix_exs_too_large}
  end

  defp validate_entry_count(entries) do
    if length(entries) <= @max_files, do: :ok, else: {:error, :too_many_mix_exs_files}
  end

  defp validate_total_bytes(entries) do
    total =
      Enum.reduce(entries, 0, fn
        {_dir, source}, acc when is_binary(source) -> acc + byte_size(source)
        _, acc -> acc
      end)

    if total <= @max_total_bytes, do: :ok, else: {:error, :mix_exs_total_too_large}
  end

  defp safe_quote(source) do
    opts = [
      existing_atoms_only: true,
      static_atoms_encoder: &static_atoms_encoder/2,
      warn_on_unnecessary_quotes: false
    ]

    case Code.string_to_quoted(source, opts) do
      {:ok, ast} -> {:ok, ast}
      {:error, _meta} -> {:error, :quote_failed}
      {:error, _meta, _msg} -> {:error, :quote_failed}
    end
  rescue
    _ -> {:error, :quote_failed}
  catch
    _kind, _reason -> {:error, :quote_failed}
  end

  # Hostile or novel identifiers become non-atoms so they cannot grow the table.
  # Note: with this encoder set, Elixir also rewrites existing atoms this way.
  defp static_atoms_encoder(atom_name, _meta) when is_binary(atom_name) do
    {:ok, {:__non_atom__, atom_name}}
  end

  defp extract_app(ast) do
    case find_project_kw(ast) do
      {:ok, kw} ->
        case keyword_get(kw, "app") do
          {:ok, name} when is_binary(name) ->
            if valid_identifier?(name) do
              {:ok, name}
            else
              {:error, :invalid_app_atom}
            end

          {:ok, _other} ->
            {:error, :dynamic_or_malformed_app}

          :error ->
            {:error, :missing_app}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_in_umbrella_deps(ast) do
    with {:ok, project_kw} <- find_project_kw(ast),
         {:ok, deps_ast} <- resolve_deps_ast(ast, project_kw) do
      parse_deps_list(deps_ast)
    end
  end

  defp find_project_kw(ast) do
    case find_function(ast, "project") do
      {:ok, body} ->
        case unwrap_do_body(body) do
          list when is_list(list) ->
            if keyword_like?(list), do: {:ok, list}, else: {:error, :project_not_keyword}

          _other ->
            {:error, :dynamic_or_malformed_project}
        end

      :error ->
        {:error, :missing_project}
    end
  end

  defp resolve_deps_ast(ast, project_kw) do
    case keyword_get(project_kw, "deps") do
      # deps() call → look up defp/def deps
      {:ok, call} ->
        case call_name(call) do
          "deps" ->
            case find_function(ast, "deps") do
              {:ok, body} -> {:ok, unwrap_do_body(body)}
              :error -> {:error, :missing_deps_function}
            end

          nil ->
            if is_list(call) do
              {:ok, call}
            else
              {:error, :dynamic_or_malformed_deps}
            end

          _other ->
            {:error, :dynamic_deps_call}
        end

      :error ->
        {:ok, []}
    end
  end

  defp parse_deps_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_dep_entry(entry) do
        {:ok, :external} ->
          {:cont, {:ok, acc}}

        {:ok, name} when is_binary(name) ->
          {:cont, {:ok, [name | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, deps} -> {:ok, Enum.reverse(deps)}
      {:error, _} = error -> error
    end
  end

  defp parse_deps_list(_), do: {:error, :dynamic_or_malformed_deps}

  # {name, opts} where name may be atom or {:__non_atom__, "name"}
  defp parse_dep_entry({name_term, opts}) when is_list(opts) do
    case ident_name(name_term) do
      name when is_binary(name) -> classify_dep(name, opts)
      :error -> {:error, :malformed_dep_entry}
    end
  end

  # {name, requirement, opts}
  defp parse_dep_entry({name_term, _requirement, opts}) when is_list(opts) do
    case ident_name(name_term) do
      name when is_binary(name) -> classify_dep(name, opts)
      :error -> {:error, :malformed_dep_entry}
    end
  end

  # {name, requirement} without opts — external
  defp parse_dep_entry({name_term, _requirement}) do
    case ident_name(name_term) do
      name when is_binary(name) -> {:ok, :external}
      :error -> {:error, :malformed_dep_entry}
    end
  end

  defp parse_dep_entry(_), do: {:error, :malformed_dep_entry}

  defp classify_dep(name, opts) do
    with true <- valid_identifier?(name),
         result <- keyword_bool(opts, "in_umbrella") do
      case result do
        {:ok, true} -> {:ok, name}
        {:ok, false} -> {:ok, :external}
        :error -> {:ok, :external}
        {:error, reason} -> {:error, reason}
      end
    else
      false ->
        {:error, {:invalid_dep_identifier, name}}
    end
  end

  defp keyword_bool(opts, key) when is_list(opts) and is_binary(key) do
    case keyword_get(opts, key) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> {:ok, false}
      {:ok, _other} -> {:error, {:non_boolean_in_umbrella, key}}
      :error -> :error
    end
  end

  defp keyword_get(list, key) when is_list(list) and is_binary(key) do
    Enum.find_value(list, :error, fn
      {k, value} ->
        case ident_name(k) do
          ^key -> {:ok, normalize_value(value)}
          _ -> nil
        end

      _ ->
        nil
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> :error
      :error -> :error
    end
  end

  defp normalize_value(true), do: true
  defp normalize_value(false), do: false

  defp normalize_value(value) when is_binary(value) or is_number(value) or is_nil(value),
    do: value

  defp normalize_value(value) do
    case ident_name(value) do
      name when is_binary(name) -> name
      :error -> value
    end
  end

  defp keyword_like?(list) when is_list(list) do
    Enum.all?(list, fn
      {k, _value} -> ident_name(k) != :error
      _ -> false
    end)
  end

  defp find_function(ast, name) when is_binary(name) do
    modules = collect_modules(ast)

    Enum.find_value(modules, :error, fn body ->
      case find_def_in_body(body, name) do
        {:ok, _} = ok -> ok
        :error -> nil
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> :error
      :error -> :error
    end
  end

  defp collect_modules(ast) do
    case call_form(ast) do
      {"defmodule", args} ->
        case extract_do_block(args) do
          {:ok, body} -> [body]
          :error -> []
        end

      {"__block__", parts} when is_list(parts) ->
        Enum.flat_map(parts, &collect_modules/1)

      _ ->
        []
    end
  end

  defp extract_do_block([_alias, opts]) when is_list(opts) do
    keyword_get_raw(opts, "do")
  end

  defp extract_do_block(_), do: :error

  defp keyword_get_raw(list, key) when is_list(list) and is_binary(key) do
    Enum.find_value(list, :error, fn
      {k, value} ->
        case ident_name(k) do
          ^key -> {:ok, value}
          _ -> nil
        end

      _ ->
        nil
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> :error
      :error -> :error
    end
  end

  defp find_def_in_body(body, name) do
    parts =
      case call_form(body) do
        {"__block__", ps} when is_list(ps) -> ps
        _ -> [body]
      end

    Enum.find_value(parts, :error, fn part ->
      case match_def(part, name) do
        {:ok, _} = ok -> ok
        :error -> nil
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> :error
      :error -> :error
    end
  end

  defp match_def(ast, name) do
    case call_form(ast) do
      {def_kind, [{fun_head, _, args}, body_or_opts]}
      when def_kind in ["def", "defp"] and (is_nil(args) or args == []) ->
        fun_name = ident_name(fun_head)

        if fun_name == name do
          extract_def_body(body_or_opts)
        else
          :error
        end

      {def_kind, [{{:__non_atom__, fun_name}, _, args}, body_or_opts]}
      when def_kind in ["def", "defp"] and is_binary(fun_name) and
             (is_nil(args) or args == []) ->
        if fun_name == name, do: extract_def_body(body_or_opts), else: :error

      _ ->
        :error
    end
  end

  defp extract_def_body(opts) when is_list(opts) do
    case keyword_get_raw(opts, "do") do
      {:ok, body} -> {:ok, body}
      :error -> :error
    end
  end

  defp extract_def_body(_), do: :error

  defp unwrap_do_body(body) do
    case call_form(body) do
      {"__block__", [single]} -> single
      _ -> body
    end
  end

  # Normalize call forms: {name, args} where name is a binary.
  defp call_form({name, _meta, args}) when is_atom(name) and is_list(args) do
    {Atom.to_string(name), args}
  end

  defp call_form({{:__non_atom__, name}, _meta, args}) when is_binary(name) and is_list(args) do
    {name, args}
  end

  defp call_form({:__block__, _meta, parts}) when is_list(parts) do
    {"__block__", parts}
  end

  defp call_form(_), do: :error

  defp call_name(ast) do
    case call_form(ast) do
      {name, _args} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp ident_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp ident_name({:__non_atom__, name}) when is_binary(name), do: name
  # Keyword-list style alias segment already handled as binary keys elsewhere
  defp ident_name(name) when is_binary(name), do: name
  defp ident_name(_), do: :error

  defp valid_identifier?(name)
       when is_binary(name) and name != "" and byte_size(name) <= @max_identifier_bytes do
    String.match?(name, ~r/^[a-z][a-z0-9_]*$/)
  end

  defp valid_identifier?(_), do: false
end
