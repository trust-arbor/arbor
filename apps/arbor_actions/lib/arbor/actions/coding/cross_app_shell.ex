defmodule Arbor.Actions.Coding.CrossApp.Shell do
  @moduledoc """
  Imperative shell for cross-app dependency-surface validation.

  Resolves an authorized workspace lease, derives changed files from the lease
  base through the dirty worktree (including untracked), parses candidate
  `apps/*/mix.exs` files as AST, selects the downstream app closure, and runs
  compile → xref → test-env compile → focused tests via `Arbor.Actions.Mix.run_mix/3`.

  The test-environment compile is an explicit `mix compile --warnings-as-errors`
  under owner-controlled `MIX_ENV=test`. The aggregate app-test monotonic deadline
  starts only after that stage succeeds, so cold test-env compilation cannot
  consume the full test-stage budget.

  Selected app test directories are expanded via git `ls-files` plus
  `ls-files --others --exclude-standard` into a deterministic bounded list of
  `*_test.exs` files (ignored/generated paths never enter validation). The
  selected root, every listed file, and intermediate path components are
  lstat'd without following symlinks. Each file runs sequentially in its own
  Mix process under `min(per-operation ceiling, remaining aggregate stage budget)`.
  """

  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.Parser
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction

  @doc "Execute cross-app validation against a leased workspace."
  @spec run(Core.input(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, context) when is_map(input) and is_map(context) do
    try do
      do_run(input, context)
    catch
      {:execution_error, reason} -> {:error, reason}
    end
  end

  def run(_input, _context), do: {:error, :invalid_cross_app_input}

  @doc false
  # Test seam: sequential per-file test stage under dual budgets.
  # 3-arity uses the same value for per-operation and aggregate stage ceilings.
  @spec run_app_tests(String.t(), [String.t()], pos_integer()) :: map()
  def run_app_tests(worktree_path, test_paths, timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) do
    run_app_tests(worktree_path, test_paths, timeout, timeout)
  end

  @doc false
  @spec run_app_tests(String.t(), [String.t()], pos_integer(), pos_integer()) :: map()
  def run_app_tests(worktree_path, test_paths, operation_timeout, test_stage_timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) do
    run_tests(worktree_path, test_paths, operation_timeout, test_stage_timeout, nil)
  end

  @doc false
  # Test seam: full compile → xref → test-compile → tests pipeline without lease setup.
  # Single timeout applies to per-operation and aggregate stage budgets.
  @spec run_validation_checks(String.t(), [String.t()], pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def run_validation_checks(worktree_path, test_paths, timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) do
    run_validation_checks(worktree_path, test_paths, timeout, timeout, nil)
  end

  @doc false
  # 4-arity: either (timeout, resource) or (operation_timeout, test_stage_timeout).
  @spec run_validation_checks(String.t(), [String.t()], pos_integer(), map() | pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def run_validation_checks(worktree_path, test_paths, timeout, resource)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) and
             is_map(resource) do
    run_validation_checks(worktree_path, test_paths, timeout, timeout, resource)
  end

  def run_validation_checks(worktree_path, test_paths, operation_timeout, test_stage_timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) do
    run_validation_checks(
      worktree_path,
      test_paths,
      operation_timeout,
      test_stage_timeout,
      nil
    )
  end

  @doc false
  @spec run_validation_checks(
          String.t(),
          [String.t()],
          pos_integer(),
          pos_integer(),
          map() | nil
        ) :: {:ok, map()} | {:error, term()}
  def run_validation_checks(
        worktree_path,
        test_paths,
        operation_timeout,
        test_stage_timeout,
        resource
      )
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) and (is_map(resource) or is_nil(resource)) do
    selection = %{test_paths: test_paths}

    try do
      run_checks(worktree_path, selection, operation_timeout, test_stage_timeout, resource)
    catch
      {:execution_error, reason} -> {:error, reason}
    end
  end

  defp do_run(input, context) do
    with {:ok, lease} <- resolve_lease(input.workspace_id, context),
         {:ok, worktree_path, base_commit} <- lease_paths(lease),
         {:ok, changed_files} <- list_changed_files(worktree_path, base_commit),
         {:ok, sources} <- load_candidate_mix_exs(worktree_path),
         {:ok, app_defs} <- Parser.parse_many(sources),
         {:ok, graph} <- Core.build_graph(app_defs),
         {:ok, selection} <- Core.select(changed_files, graph),
         {:ok, checks} <-
           MixAction.with_validation_resource(
             input.workspace_id,
             context,
             fn resource ->
               run_checks(
                 worktree_path,
                 selection,
                 input.timeout,
                 input.test_stage_timeout,
                 resource
               )
             end,
             # Resource setup is bound by the per-operation ceiling, not aggregate stage.
             timeout: input.timeout
           ) do
      evidence =
        Core.show(%{
          selection: selection,
          checks: checks,
          base_commit: base_commit
        })

      feedback_json = Jason.encode!(evidence)
      {:ok, Map.put(evidence, :feedback_json, feedback_json)}
    end
  end

  defp resolve_lease(workspace_id, context) do
    caller = %{
      task_id: Workspace.context_task_id(context),
      principal_id: Workspace.context_principal_id(context)
    }

    case WorkspaceLeaseRegistry.inspect_lease(workspace_id, caller) do
      {:ok, lease} -> {:ok, lease}
      {:error, :not_found} -> {:error, :workspace_not_found}
      {:error, :unauthorized} -> {:error, :workspace_unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lease_paths(lease) when is_map(lease) do
    worktree = map_value(lease, :worktree_path)
    base = map_value(lease, :base_commit)

    cond do
      not is_binary(worktree) or worktree == "" ->
        {:error, :missing_worktree_path}

      not File.dir?(worktree) ->
        {:error, :worktree_missing}

      not is_binary(base) or base == "" ->
        {:error, :missing_base_commit}

      true ->
        {:ok, worktree, base}
    end
  end

  defp list_changed_files(worktree_path, base_commit) do
    with {:ok, tracked} <-
           git(worktree_path, ["diff", "--name-only", "--find-renames", "-z", base_commit]),
         {:ok, untracked} <-
           git(worktree_path, ["ls-files", "--others", "--exclude-standard", "-z"]) do
      files =
        (split_z(tracked) ++ split_z(untracked))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, files}
    else
      {:error, reason} -> {:error, {:changed_files_failed, reason}}
    end
  end

  defp load_candidate_mix_exs(worktree_path) do
    with {:ok, tracked} <- git(worktree_path, ["ls-files", "-z", "--", "apps/*/mix.exs"]),
         {:ok, untracked} <-
           git(worktree_path, [
             "ls-files",
             "--others",
             "--exclude-standard",
             "-z",
             "--",
             "apps/*/mix.exs"
           ]) do
      paths =
        (split_z(tracked) ++ split_z(untracked))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      Enum.reduce_while(paths, {:ok, []}, fn rel, {:ok, acc} ->
        case app_dir_for_mix_exs(rel) do
          {:ok, dir} ->
            abs = Path.join(worktree_path, rel)

            case File.read(abs) do
              {:ok, source} ->
                {:cont, {:ok, [{dir, source} | acc]}}

              {:error, reason} ->
                {:halt, {:error, {:mix_exs_read_failed, rel, reason}}}
            end

          :error ->
            {:halt, {:error, {:invalid_mix_exs_path, rel}}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    else
      {:error, reason} -> {:error, {:mix_exs_list_failed, reason}}
    end
  end

  defp app_dir_for_mix_exs(path) do
    case Path.split(path) do
      ["apps", dir, "mix.exs"] when dir != "" -> {:ok, dir}
      _ -> :error
    end
  end

  defp run_checks(worktree_path, selection, operation_timeout, test_stage_timeout, resource) do
    compile = run_compile(worktree_path, operation_timeout, resource)

    if compile["passed"] do
      xref = run_xref(worktree_path, operation_timeout, resource)

      if xref["passed"] do
        test_compile = run_test_compile(worktree_path, operation_timeout, resource)

        test =
          if test_compile["passed"] do
            # Aggregate test-stage budget starts only after MIX_ENV=test compile.
            run_tests(
              worktree_path,
              selection.test_paths,
              operation_timeout,
              test_stage_timeout,
              resource
            )
          else
            Core.skipped_check("test_compile_failed")
          end

        {:ok, %{compile: compile, xref: xref, test_compile: test_compile, test: test}}
      else
        {:ok,
         %{
           compile: compile,
           xref: xref,
           test_compile: Core.skipped_check("xref_failed"),
           test: Core.skipped_check("xref_failed")
         }}
      end
    else
      {:ok,
       %{
         compile: compile,
         xref: Core.skipped_check("compile_failed"),
         test_compile: Core.skipped_check("compile_failed"),
         test: Core.skipped_check("compile_failed")
       }}
    end
  end

  defp run_compile(path, timeout, resource) do
    case run_mix(path, ["compile", "--warnings-as-errors"],
           timeout: timeout,
           validation_resource: resource
         ) do
      {:ok, result} ->
        Core.completed_check(Core.feedback_from_result(result))

      {:error, reason} ->
        throw({:execution_error, {:compile_execution_failed, reason}})
    end
  end

  defp run_xref(path, timeout, resource) do
    # Evidence only — do not pass --fail-above; this repository has baseline
    # compile-connected cycles. Zero-cycle validation is not claimed.
    case run_mix(path, ["xref", "graph"], timeout: timeout, validation_resource: resource) do
      {:ok, result} ->
        exit_code = Map.get(result, :exit_code) || Map.get(result, "exit_code")

        Core.completed_check(Core.feedback_from_result(result),
          reason: if(exit_code == 0, do: nil, else: "xref_failed")
        )

      {:error, reason} ->
        throw({:execution_error, {:xref_execution_failed, reason}})
    end
  end

  defp run_test_compile(path, timeout, resource) do
    # Explicit MIX_ENV=test compile before the aggregate app-test deadline starts.
    # Owner-controlled safe env only; same per-operation timeout as other stages.
    case run_mix(path, ["compile", "--warnings-as-errors"],
           timeout: timeout,
           validation_resource: resource,
           env: %{"MIX_ENV" => "test"}
         ) do
      {:ok, result} ->
        feedback = Core.feedback_from_result(result)
        passed = Map.get(feedback, "passed") == true

        Core.completed_check(feedback,
          reason: if(passed, do: nil, else: "test_compile_failed")
        )

      {:error, reason} ->
        throw({:execution_error, {:test_compile_execution_failed, reason}})
    end
  end

  defp run_tests(_path, [], _operation_timeout, _test_stage_timeout, _resource) do
    Core.empty_pass_check("no_affected_app_tests")
  end

  defp run_tests(path, test_paths, operation_timeout, test_stage_timeout, resource)
       when is_list(test_paths) do
    case expand_test_files(path, test_paths) do
      {:ok, []} ->
        Core.empty_pass_check("no_existing_test_files")

      {:ok, files} ->
        # One shared absolute monotonic deadline for the whole test stage — not N× timeout.
        deadline = monotonic_ms() + test_stage_timeout
        run_tests_sequential(path, files, deadline, operation_timeout, resource, [])

      {:error, reason} ->
        throw({:execution_error, {:test_file_enumeration_failed, reason}})
    end
  end

  defp run_tests_sequential(
         worktree_path,
         remaining_paths,
         deadline,
         operation_timeout,
         resource,
         acc
       ) do
    # Shared aggregate deadline checked before every child (including the first).
    remaining_ms = deadline - monotonic_ms()

    case Core.next_test_step(remaining_ms, remaining_paths, operation_timeout) do
      :complete ->
        Core.aggregate_test_check(Enum.reverse(acc))

      {:timeout, path, _rest} ->
        # Budget already exhausted — do not launch this or any later child.
        # Preserve successful prior child evidence in `acc`.
        Core.aggregate_test_check(Enum.reverse([Core.budget_exhausted_result(path) | acc]))

      {:run, path, budget_ms, rest} ->
        mix_opts =
          [timeout: budget_ms]
          |> then(fn opts ->
            if resource, do: Keyword.put(opts, :validation_resource, resource), else: opts
          end)

        case run_mix(worktree_path, ["test", "--", path], mix_opts) do
          {:ok, result} ->
            # Re-check shared deadline immediately after every child, including the final one.
            remaining_after = deadline - monotonic_ms()
            runner_timeout = Core.runner_timed_out?(result)
            timed_out = Core.child_timed_out?(runner_timeout, remaining_after)

            app_result =
              Core.classify_app_test_result(path, Core.feedback_from_result(result),
                timed_out: timed_out
              )

            # Stop after first failed/timed-out file — overall result is failed.
            # Prior successful children remain in the aggregate evidence.
            if app_result.passed do
              run_tests_sequential(
                worktree_path,
                rest,
                deadline,
                operation_timeout,
                resource,
                [app_result | acc]
              )
            else
              Core.aggregate_test_check(Enum.reverse([app_result | acc]))
            end

          {:error, reason} ->
            # Preserve the exact selected file path from expansion.
            throw({:execution_error, {:test_execution_failed, path, reason}})
        end

      {:error, reason} ->
        # Malformed step input must never silently complete as success.
        throw({:execution_error, {:invalid_test_step, reason}})
    end
  end

  # Expand selected app test directories into deterministic relative *_test.exs paths.
  # Inventory is git tracked + untracked (exclude-standard) only — ignored and
  # generated files never enter validation. Bound inventory size before any
  # per-entry lstat work. Symlink roots/components/files fail closed.
  defp expand_test_files(worktree_path, test_dirs) when is_list(test_dirs) do
    with {:ok, selected_dirs} <- prepare_selected_test_dirs(worktree_path, test_dirs),
         {:ok, test_paths} <- git_list_test_paths(worktree_path, selected_dirs),
         {:ok, verified} <-
           verify_listed_test_files(worktree_path, selected_dirs, test_paths) do
      Core.normalize_expanded_test_files(verified)
    end
  end

  defp prepare_selected_test_dirs(worktree_path, test_dirs) do
    Enum.reduce_while(test_dirs, {:ok, []}, fn dir, {:ok, acc} ->
      case prepare_one_selected_dir(worktree_path, dir) do
        {:ok, :missing} ->
          {:cont, {:ok, acc}}

        {:ok, normalized} ->
          {:cont, {:ok, acc ++ [normalized]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp prepare_one_selected_dir(worktree_path, rel_dir) when is_binary(rel_dir) do
    with {:ok, trimmed} <- validate_test_dir_relpath(rel_dir) do
      abs_dir = Path.join(worktree_path, trimmed)

      case File.lstat(abs_dir) do
        {:error, :enoent} ->
          {:ok, :missing}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, {:symlink_rejected, :test_dir, trimmed}}

        {:ok, %File.Stat{type: :directory}} ->
          {:ok, trimmed}

        {:ok, %File.Stat{type: other}} ->
          {:error, {:unexpected_test_path_type, :test_dir, trimmed, other}}

        {:error, reason} ->
          {:error, {:test_path_stat_failed, :test_dir, trimmed, reason}}
      end
    end
  end

  defp prepare_one_selected_dir(_worktree_path, rel_dir),
    do: {:error, {:invalid_test_dir, rel_dir}}

  defp validate_test_dir_relpath(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, {:invalid_test_dir, path}}

      not String.valid?(trimmed) ->
        {:error, {:invalid_test_dir, path}}

      String.contains?(trimmed, <<0>>) ->
        {:error, {:invalid_test_dir, path}}

      String.starts_with?(trimmed, "/") ->
        {:error, {:invalid_test_dir, path}}

      String.contains?(trimmed, "..") ->
        {:error, {:invalid_test_dir, path}}

      true ->
        case Path.split(trimmed) do
          ["apps", app, "test"] when app != "" ->
            {:ok, Path.join(["apps", app, "test"])}

          _ ->
            {:error, {:invalid_test_dir, path}}
        end
    end
  end

  defp validate_test_dir_relpath(path), do: {:error, {:invalid_test_dir, path}}

  defp git_list_test_paths(_worktree_path, []) do
    {:ok, []}
  end

  defp git_list_test_paths(worktree_path, selected_dirs) when is_list(selected_dirs) do
    # Pathspecs are the already-validated selected dirs only (bounded by selection).
    with {:ok, tracked} <-
           git(worktree_path, ["ls-files", "-z", "--" | selected_dirs]),
         {:ok, untracked} <-
           git(worktree_path, [
             "ls-files",
             "--others",
             "--exclude-standard",
             "-z",
             "--" | selected_dirs
           ]) do
      # Preserve exact NUL-delimited path bytes — never String.trim/1.
      # Bound the combined raw inventory before suffix filter / dedup / lstat.
      raw_entries =
        (split_z(tracked) ++ split_z(untracked))
        |> Enum.reject(&(&1 == ""))

      if length(raw_entries) > Core.max_git_inventory_entries() do
        {:error, :too_many_git_inventory_entries}
      else
        paths =
          raw_entries
          |> Enum.filter(&String.ends_with?(&1, "_test.exs"))
          |> Enum.uniq()
          |> Enum.sort()

        if length(paths) > Core.max_expanded_test_files() do
          {:error, :too_many_test_files}
        else
          {:ok, paths}
        end
      end
    else
      {:error, reason} -> {:error, {:test_file_list_failed, reason}}
    end
  end

  defp verify_listed_test_files(worktree_path, selected_dirs, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case verify_one_listed_test_file(worktree_path, selected_dirs, path) do
        {:ok, verified_path} ->
          {:cont, {:ok, [verified_path | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp verify_one_listed_test_file(worktree_path, selected_dirs, path) do
    with :ok <- assert_under_selected_dir(path, selected_dirs),
         :ok <- assert_no_symlink_path_components(worktree_path, path),
         :ok <- assert_regular_test_file(worktree_path, path) do
      {:ok, path}
    end
  end

  # Exact segment-prefix match against a selected dir (apps/<app>/test/...).
  defp assert_under_selected_dir(path, selected_dirs) when is_binary(path) do
    segs = Path.split(path)

    if Enum.any?(selected_dirs, fn dir ->
         dsegs = Path.split(dir)
         List.starts_with?(segs, dsegs) and length(segs) > length(dsegs)
       end) do
      :ok
    else
      {:error, {:path_outside_selection, path}}
    end
  end

  # lstat every path component without following symlinks so a symlink parent
  # cannot redirect reads outside the selected tree.
  defp assert_no_symlink_path_components(worktree_path, rel_path) do
    segs = Path.split(rel_path)
    total = length(segs)

    Enum.reduce_while(1..total, :ok, fn n, :ok ->
      partial = Path.join(Enum.take(segs, n))
      abs = Path.join(worktree_path, partial)
      is_leaf = n == total

      case File.lstat(abs) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:symlink_rejected, :path_component, partial}}}

        {:ok, %File.Stat{type: :directory}} when not is_leaf ->
          {:cont, :ok}

        {:ok, %File.Stat{type: :regular}} when is_leaf ->
          {:cont, :ok}

        {:ok, %File.Stat{type: other}} ->
          kind = if is_leaf, do: :test_file, else: :path_component
          {:halt, {:error, {:unexpected_test_path_type, kind, partial, other}}}

        {:error, reason} ->
          kind = if is_leaf, do: :test_file, else: :path_component
          {:halt, {:error, {:test_path_stat_failed, kind, partial, reason}}}
      end
    end)
  end

  defp assert_regular_test_file(worktree_path, rel_path) do
    abs = Path.join(worktree_path, rel_path)

    case File.lstat(abs) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_rejected, :test_file, rel_path}}

      {:ok, %File.Stat{type: other}} ->
        {:error, {:unexpected_test_path_type, :test_file, rel_path, other}}

      {:error, reason} ->
        {:error, {:test_path_stat_failed, :test_file, rel_path, reason}}
    end
  end

  # System-owned capacity for every contained Mix validation stage (compile,
  # xref, test-env compile, test). Not caller-controlled; never exposed on a
  # Jido schema. Shell validates the closed profile atom.
  defp run_mix(path, args, opts) do
    runner = Application.get_env(:arbor_actions, :cross_app_mix_runner, &MixAction.run_mix/3)
    opts = Keyword.put(opts, :resource_profile, :intensive)
    runner.(path, args, opts)
  end

  defp monotonic_ms do
    clock =
      Application.get_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
        System.monotonic_time(:millisecond)
      end)

    clock.()
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp split_z(output) when is_binary(output) do
    String.split(output, <<0>>, trim: true)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
