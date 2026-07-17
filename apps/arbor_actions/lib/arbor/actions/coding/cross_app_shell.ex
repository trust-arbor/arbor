defmodule Arbor.Actions.Coding.CrossApp.Shell do
  @moduledoc """
  Imperative shell for cross-app dependency-surface validation.

  Resolves an authorized workspace lease, derives changed files from the lease
  base through the dirty worktree (including untracked), parses candidate
  `apps/*/mix.exs` files as AST, selects the downstream app closure, and runs
  compile → xref → test-env compile → focused tests via `Arbor.Actions.Mix.run_mix/3`.

  The test-environment compile is an explicit `mix compile --warnings-as-errors`
  under owner-controlled `MIX_ENV=test`. The shared app-test monotonic deadline
  starts only after that stage succeeds, so cold test-env compilation cannot
  consume the full test-stage budget.

  Affected-app tests run **sequentially**, one existing app test directory per
  fresh Mix process, under a single monotonic budget equal to the action's
  validated timeout for the test stage (not N× timeout).
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
  # Test seam: sequential per-app test stage under a shared monotonic budget.
  @spec run_app_tests(String.t(), [String.t()], pos_integer()) :: map()
  def run_app_tests(worktree_path, test_paths, timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) do
    run_tests(worktree_path, test_paths, timeout)
  end

  @doc false
  # Test seam: full compile → xref → test-compile → tests pipeline without lease setup.
  @spec run_validation_checks(String.t(), [String.t()], pos_integer(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def run_validation_checks(worktree_path, test_paths, timeout, resource \\ nil)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) do
    selection = %{test_paths: test_paths}

    try do
      run_checks(worktree_path, selection, timeout, resource)
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
               run_checks(worktree_path, selection, input.timeout, resource)
             end,
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

  defp run_checks(worktree_path, selection, timeout, resource) do
    compile = run_compile(worktree_path, timeout, resource)

    if compile["passed"] do
      xref = run_xref(worktree_path, timeout, resource)

      if xref["passed"] do
        test_compile = run_test_compile(worktree_path, timeout, resource)

        test =
          if test_compile["passed"] do
            # Shared test-stage budget starts only after MIX_ENV=test compile.
            run_tests(worktree_path, selection.test_paths, timeout, resource)
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
    # Explicit MIX_ENV=test compile before the shared app-test deadline starts.
    # Owner-controlled safe env only; same per-check timeout as other stages.
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

  defp run_tests(_path, [], _timeout, _resource) do
    Core.empty_pass_check("no_affected_app_tests")
  end

  defp run_tests(path, test_paths, timeout, resource) when is_list(test_paths) do
    # Only pass existing test directories so mix does not fail on missing paths
    # for apps that declare no tests yet. Preserve selection order.
    existing =
      Enum.filter(test_paths, fn rel -> File.dir?(Path.join(path, rel)) end)

    if existing == [] do
      Core.empty_pass_check("no_existing_test_dirs")
    else
      # One shared absolute monotonic deadline for the whole test stage — not N× timeout.
      deadline = monotonic_ms() + timeout
      run_tests_sequential(path, existing, deadline, resource, [])
    end
  end

  # Public test seam keeps the 3-arity form without a validation resource.
  defp run_tests(path, test_paths, timeout) when is_list(test_paths) do
    run_tests(path, test_paths, timeout, nil)
  end

  defp run_tests_sequential(worktree_path, remaining_paths, deadline, resource, acc) do
    # Shared deadline checked before every child (including the first).
    remaining_ms = deadline - monotonic_ms()

    case Core.next_test_step(remaining_ms, remaining_paths) do
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

            # Stop after first failed/timed-out app — overall result is failed.
            # Prior successful children remain in the aggregate evidence.
            if app_result.passed do
              run_tests_sequential(worktree_path, rest, deadline, resource, [app_result | acc])
            else
              Core.aggregate_test_check(Enum.reverse([app_result | acc]))
            end

          {:error, reason} ->
            # Preserve the exact selected path from the owner-derived selection.
            throw({:execution_error, {:test_execution_failed, path, reason}})
        end
    end
  end

  defp run_mix(path, args, opts) do
    runner = Application.get_env(:arbor_actions, :cross_app_mix_runner, &MixAction.run_mix/3)
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
