defmodule Arbor.Actions.Coding.CrossApp.Core do
  @moduledoc """
  Pure input, dependency-selection, and evidence logic for cross-app validation.

  The imperative shell supplies changed files and parsed app metadata. This module
  decides the affected-app closure and formats JSON-clean validation evidence
  without filesystem, process, clock, or registry operations.
  """

  @default_timeout 300_000
  @minimum_timeout 1_000
  @maximum_timeout 600_000
  @allowed_param_keys [:workspace_id, :timeout]
  @allowed_param_string_keys Enum.map(@allowed_param_keys, &Atom.to_string/1)

  @max_changed_files 2_000
  @max_apps 256
  @max_identifier_bytes 64
  @max_test_paths 256
  @max_output_list 2_000

  @root_wide_exact MapSet.new([
                     "mix.exs",
                     "mix.lock",
                     ".formatter.exs",
                     ".tool-versions"
                   ])

  @typedoc "Normalized, side-effect-free action input."
  @type input :: %{
          workspace_id: String.t(),
          timeout: pos_integer()
        }

  @typedoc "One umbrella app's static dependency metadata."
  @type app_def :: %{
          dir: String.t(),
          app: String.t(),
          deps: [String.t()]
        }

  @typedoc "Dependency graph keyed by app directory/name."
  @type graph :: %{
          apps: [String.t()],
          # app => upstream in-umbrella deps it depends on
          depends_on: %{optional(String.t()) => [String.t()]},
          # app => downstream apps that depend on it
          depended_by: %{optional(String.t()) => [String.t()]}
        }

  @typedoc "Selection result for changed files against a graph."
  @type selection :: %{
          changed_files: [String.t()],
          changed_apps: [String.t()],
          affected_apps: [String.t()],
          test_paths: [String.t()],
          root_wide: boolean()
        }

  @doc "Construct and validate the action's deliberately narrow input surface."
  @spec new(map()) :: {:ok, input()} | {:error, atom()}
  def new(params) when is_map(params) do
    with :ok <- validate_param_keys(params),
         {:ok, workspace_id} <- validate_workspace_id(param(params, :workspace_id)),
         {:ok, timeout} <- validate_timeout(param(params, :timeout)) do
      {:ok, %{workspace_id: workspace_id, timeout: timeout}}
    end
  end

  def new(_params), do: {:error, :invalid_parameters}

  @doc "Build a dependency graph from pure app definitions. Fails closed on ambiguity."
  @spec build_graph([app_def()]) :: {:ok, graph()} | {:error, term()}
  def build_graph(app_defs) when is_list(app_defs) do
    with :ok <- validate_app_def_count(app_defs),
         :ok <- validate_app_defs(app_defs) do
      apps = app_defs |> Enum.map(& &1.dir) |> Enum.sort()
      app_set = MapSet.new(apps)

      depends_on =
        Map.new(app_defs, fn %{dir: dir, deps: deps} ->
          {dir, deps |> Enum.uniq() |> Enum.sort()}
        end)

      with :ok <- validate_dep_targets(depends_on, app_set) do
        depended_by =
          Enum.reduce(depends_on, %{}, fn {app, deps}, acc ->
            Enum.reduce(deps, acc, fn dep, acc2 ->
              Map.update(acc2, dep, [app], fn existing -> [app | existing] end)
            end)
          end)
          |> Map.new(fn {k, v} -> {k, v |> Enum.uniq() |> Enum.sort()} end)

        {:ok,
         %{
           apps: apps,
           depends_on: depends_on,
           depended_by: depended_by
         }}
      end
    end
  end

  def build_graph(_), do: {:error, :invalid_app_defs}

  @doc """
  Select changed and affected apps from changed files and a dependency graph.

  Directly changed apps plus every downstream in-umbrella dependent. Root
  build-impact files select all apps. Unrelated docs do not widen selection.
  """
  @spec select([String.t()], graph()) :: {:ok, selection()} | {:error, term()}
  def select(changed_files, graph) when is_list(changed_files) and is_map(graph) do
    with {:ok, files} <- normalize_changed_files(changed_files),
         {:ok, changed_apps, root_wide} <- classify_files(files, graph) do
      affected_apps =
        if root_wide do
          graph.apps
        else
          downstream_closure(changed_apps, graph.depended_by)
        end

      test_paths =
        affected_apps
        |> Enum.map(&("apps/" <> &1 <> "/test"))
        |> Enum.take(@max_test_paths)

      {:ok,
       %{
         changed_files: Enum.take(files, @max_output_list),
         changed_apps: changed_apps,
         affected_apps: affected_apps,
         test_paths: test_paths,
         root_wide: root_wide
       }}
    end
  end

  def select(_, _), do: {:error, :invalid_selection_input}

  @doc "Assemble bounded JSON-clean evidence from selection and check results."
  @spec show(map()) :: map()
  def show(%{
        selection: selection,
        checks: checks,
        base_commit: base_commit
      })
      when is_map(selection) and is_map(checks) do
    compile = Map.get(checks, :compile) || Map.get(checks, "compile") || %{}
    xref = Map.get(checks, :xref) || Map.get(checks, "xref") || %{}
    test = Map.get(checks, :test) || Map.get(checks, "test") || %{}

    compile_passed = Map.get(compile, :passed) || Map.get(compile, "passed") || false
    xref_passed = Map.get(xref, :passed) || Map.get(xref, "passed") || false
    test_passed = Map.get(test, :passed) || Map.get(test, "passed") || false

    passed = compile_passed and xref_passed and test_passed
    reason = overall_reason(passed, compile, xref, test)

    %{
      passed: passed,
      reason: reason,
      base_commit: base_commit,
      changed_files: selection.changed_files,
      changed_apps: selection.changed_apps,
      affected_apps: selection.affected_apps,
      test_paths: selection.test_paths,
      root_wide: selection.root_wide,
      compile: normalize_check(compile),
      xref: normalize_check(xref),
      test: normalize_check(test)
    }
  end

  @doc false
  def default_timeout, do: @default_timeout

  @doc false
  def maximum_timeout, do: @maximum_timeout

  @doc false
  def root_wide_path?(path) when is_binary(path) do
    cond do
      MapSet.member?(@root_wide_exact, path) -> true
      String.starts_with?(path, "config/") -> true
      true -> false
    end
  end

  def root_wide_path?(_), do: false

  @doc false
  def app_dir_from_path(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app | _rest] when app != "" ->
        if valid_identifier?(app), do: {:ok, app}, else: {:error, {:invalid_app_dir, app}}

      _ ->
        :not_app_path
    end
  end

  def app_dir_from_path(_), do: :not_app_path

  @doc "Build a skipped-check map (domain failure cascade)."
  @spec skipped_check(String.t()) :: map()
  def skipped_check(reason) when is_binary(reason) do
    %{
      "status" => "skipped",
      "passed" => false,
      "exit_code" => nil,
      "reason" => reason,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => sha256(""),
      "stderr_sha256" => sha256("")
    }
  end

  @doc "Build a completed-check map from Mix feedback plus optional status."
  @spec completed_check(map(), keyword()) :: map()
  def completed_check(feedback, opts \\ []) when is_map(feedback) do
    passed = Map.get(feedback, "passed") || Map.get(feedback, :passed) || false
    exit_code = Map.get(feedback, "exit_code") || Map.get(feedback, :exit_code)

    %{
      "status" => Keyword.get(opts, :status, "completed"),
      "passed" => passed == true,
      "exit_code" => exit_code,
      "reason" => Keyword.get(opts, :reason),
      "stdout_excerpt" =>
        Map.get(feedback, "stdout_excerpt") || Map.get(feedback, :stdout_excerpt) || "",
      "stderr_excerpt" =>
        Map.get(feedback, "stderr_excerpt") || Map.get(feedback, :stderr_excerpt) || "",
      "stdout_truncated" =>
        Map.get(feedback, "stdout_truncated") || Map.get(feedback, :stdout_truncated) || false,
      "stderr_truncated" =>
        Map.get(feedback, "stderr_truncated") || Map.get(feedback, :stderr_truncated) || false,
      "stdout_sha256" =>
        Map.get(feedback, "stdout_sha256") || Map.get(feedback, :stdout_sha256) || sha256(""),
      "stderr_sha256" =>
        Map.get(feedback, "stderr_sha256") || Map.get(feedback, :stderr_sha256) || sha256("")
    }
  end

  @doc "No-op passed check when there is nothing to run (e.g. zero test paths)."
  @spec empty_pass_check(String.t()) :: map()
  def empty_pass_check(reason) when is_binary(reason) do
    %{
      "status" => "skipped",
      "passed" => true,
      "exit_code" => 0,
      "reason" => reason,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => sha256(""),
      "stderr_sha256" => sha256("")
    }
  end

  defp validate_param_keys(params) do
    valid? =
      Enum.all?(Map.keys(params), fn key ->
        key in @allowed_param_keys or key in @allowed_param_string_keys
      end)

    if valid?, do: :ok, else: {:error, :unsupported_parameter}
  end

  defp validate_workspace_id(value)
       when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      {:error, :invalid_workspace_id}
    end
  end

  defp validate_workspace_id(_value), do: {:error, :invalid_workspace_id}

  defp validate_timeout(nil), do: {:ok, @default_timeout}

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout >= @minimum_timeout and timeout <= @maximum_timeout,
       do: {:ok, timeout}

  defp validate_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {parsed, ""} ->
        if Integer.to_string(parsed) == timeout,
          do: validate_timeout(parsed),
          else: {:error, :invalid_timeout}

      _other ->
        {:error, :invalid_timeout}
    end
  end

  defp validate_timeout(_timeout), do: {:error, :invalid_timeout}

  defp validate_app_def_count(app_defs) do
    if length(app_defs) <= @max_apps, do: :ok, else: {:error, :too_many_apps}
  end

  defp validate_app_defs(app_defs) do
    dirs = Enum.map(app_defs, & &1.dir)
    apps = Enum.map(app_defs, & &1.app)

    cond do
      Enum.any?(app_defs, fn def ->
        not is_binary(def.dir) or not is_binary(def.app) or not is_list(def.deps)
      end) ->
        {:error, :malformed_app_def}

      Enum.any?(app_defs, fn def -> def.dir != def.app end) ->
        {:error, :app_dir_name_mismatch}

      Enum.any?(dirs, &(not valid_identifier?(&1))) ->
        {:error, :invalid_app_identifier}

      Enum.any?(apps, &(not valid_identifier?(&1))) ->
        {:error, :invalid_app_identifier}

      Enum.any?(app_defs, fn def -> Enum.any?(def.deps, &(not valid_identifier?(&1))) end) ->
        {:error, :invalid_dep_identifier}

      length(Enum.uniq(dirs)) != length(dirs) ->
        {:error, :duplicate_app_dir}

      length(Enum.uniq(apps)) != length(apps) ->
        {:error, :duplicate_app_name}

      true ->
        :ok
    end
  end

  defp validate_dep_targets(depends_on, app_set) do
    unknown =
      depends_on
      |> Enum.flat_map(fn {from, deps} ->
        Enum.reject(deps, &MapSet.member?(app_set, &1))
        |> Enum.map(&{from, &1})
      end)

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_in_umbrella_dep, Enum.sort(unknown)}}
    end
  end

  defp normalize_changed_files(files) do
    if length(files) > @max_changed_files do
      {:error, :too_many_changed_files}
    else
      normalized =
        files
        |> Enum.map(&normalize_path/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      if Enum.any?(normalized, &(byte_size(&1) > 1_024)) do
        {:error, :changed_file_path_too_long}
      else
        {:ok, normalized}
      end
    end
  end

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> nil
      String.contains?(trimmed, <<0>>) -> nil
      String.starts_with?(trimmed, "/") -> nil
      String.contains?(trimmed, "..") -> nil
      true -> trimmed
    end
  end

  defp normalize_path(_), do: nil

  defp classify_files(files, graph) do
    app_set = MapSet.new(graph.apps)

    Enum.reduce_while(files, {:ok, MapSet.new(), false}, fn path, {:ok, apps, root_wide} ->
      cond do
        root_wide_path?(path) ->
          {:cont, {:ok, apps, true}}

        true ->
          case app_dir_from_path(path) do
            {:ok, app} ->
              if MapSet.member?(app_set, app) do
                {:cont, {:ok, MapSet.put(apps, app), root_wide}}
              else
                # Changed path under apps/<unknown>/ — fail closed unless the
                # path is merely an untracked junk file outside known apps.
                # Known-app directories are the only authority for selection.
                {:halt, {:error, {:changed_unknown_app, app}}}
              end

            :not_app_path ->
              # docs, scripts, etc. — do not widen
              {:cont, {:ok, apps, root_wide}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, apps, root_wide} ->
        {:ok, apps |> MapSet.to_list() |> Enum.sort(), root_wide}

      {:error, _} = error ->
        error
    end
  end

  defp downstream_closure(seeds, depended_by) do
    seeds = MapSet.new(seeds)

    expand = fn
      expand_fun, frontier, seen ->
        next =
          frontier
          |> Enum.flat_map(fn app -> Map.get(depended_by, app, []) end)
          |> Enum.reject(&MapSet.member?(seen, &1))

        if next == [] do
          seen
        else
          next_set = MapSet.new(next)
          expand_fun.(expand_fun, next, MapSet.union(seen, next_set))
        end
    end

    seeds
    |> then(fn s -> expand.(expand, MapSet.to_list(s), s) end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp valid_identifier?(name)
       when is_binary(name) and name != "" and byte_size(name) <= @max_identifier_bytes do
    String.match?(name, ~r/^[a-z][a-z0-9_]*$/)
  end

  defp valid_identifier?(_), do: false

  defp overall_reason(true, _compile, _xref, _test), do: "cross_app_validated"

  defp overall_reason(false, compile, xref, test) do
    cond do
      check_failed?(compile) -> check_reason(compile, "compile_failed")
      check_failed?(xref) -> check_reason(xref, "xref_failed")
      check_failed?(test) -> check_reason(test, "tests_failed")
      true -> "validation_failed"
    end
  end

  defp check_failed?(check) do
    passed = Map.get(check, :passed) || Map.get(check, "passed")
    passed != true
  end

  defp check_reason(check, default) do
    Map.get(check, :reason) || Map.get(check, "reason") || default
  end

  defp normalize_check(check) when is_map(check) do
    %{
      "status" =>
        to_string_value(Map.get(check, :status) || Map.get(check, "status") || "unknown"),
      "passed" => Map.get(check, :passed) || Map.get(check, "passed") || false,
      "exit_code" => Map.get(check, :exit_code) || Map.get(check, "exit_code"),
      "reason" => Map.get(check, :reason) || Map.get(check, "reason"),
      "stdout_excerpt" =>
        Map.get(check, :stdout_excerpt) || Map.get(check, "stdout_excerpt") || "",
      "stderr_excerpt" =>
        Map.get(check, :stderr_excerpt) || Map.get(check, "stderr_excerpt") || "",
      "stdout_truncated" =>
        Map.get(check, :stdout_truncated) || Map.get(check, "stdout_truncated") || false,
      "stderr_truncated" =>
        Map.get(check, :stderr_truncated) || Map.get(check, "stderr_truncated") || false,
      "stdout_sha256" =>
        Map.get(check, :stdout_sha256) || Map.get(check, "stdout_sha256") || sha256(""),
      "stderr_sha256" =>
        Map.get(check, :stderr_sha256) || Map.get(check, "stderr_sha256") || sha256("")
    }
  end

  defp normalize_check(_), do: skipped_check("missing_check")

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: inspect(value)

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp sha256(output) when is_binary(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
