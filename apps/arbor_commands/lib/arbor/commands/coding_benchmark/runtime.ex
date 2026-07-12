defmodule Arbor.Commands.CodingBenchmark.Runtime do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.Config, as: OrchestratorConfig

  @app :arbor_commands
  @workspace_root_key :coding_benchmark_workspace_root
  @artifact_root_key :coding_benchmark_artifact_root
  @timeout_key :coding_benchmark_execution_timeout_ms
  @cancellation_timeout_key :coding_benchmark_cancellation_timeout_ms
  @min_timeout_ms 10
  @max_timeout_ms 86_400_000
  @max_cancellation_timeout_ms 30_000

  @type config :: %{
          workspace_root: String.t(),
          artifact_root: String.t(),
          execution_timeout_ms: pos_integer(),
          cancellation_timeout_ms: pos_integer()
        }

  @type topology :: %{
          workdir: String.t(),
          pair_root: String.t(),
          worktree_root: String.t(),
          artifact_root: String.t()
        }

  @spec load() :: {:ok, config()} | {:error, {:benchmark_setup_error, term()}}
  def load do
    with {:ok, workspace_root} <- configured_directory(@workspace_root_key),
         {:ok, artifact_root} <- configured_directory(@artifact_root_key),
         :ok <- require_distinct_child(artifact_root, workspace_root),
         {:ok, timeout} <-
           configured_timeout(@timeout_key, @min_timeout_ms, @max_timeout_ms),
         {:ok, cancellation_timeout} <-
           configured_timeout(
             @cancellation_timeout_key,
             @min_timeout_ms,
             @max_cancellation_timeout_ms
           ) do
      {:ok,
       %{
         artifact_root: artifact_root,
         cancellation_timeout_ms: cancellation_timeout,
         execution_timeout_ms: timeout,
         workspace_root: workspace_root
       }}
    end
  end

  @spec preflight_production(config()) ::
          :ok | {:error, {:benchmark_setup_error, term()}}
  def preflight_production(config) do
    with {:ok, repo_roots} <- orchestrator_roots(:repo),
         :ok <- require_admitted(config.workspace_root, repo_roots, :coding_repo_roots),
         {:ok, worktree_roots} <- orchestrator_roots(:worktree),
         :ok <-
           require_admitted(
             config.workspace_root,
             worktree_roots,
             :coding_worktree_roots
           ),
         {:ok, logs_root} <- canonical_directory(OrchestratorConfig.coding_pipeline_logs_root()),
         true <- logs_root == config.artifact_root do
      :ok
    else
      false -> setup_error(:coding_pipeline_logs_root_mismatch)
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      {:error, reason} -> setup_error(reason)
    end
  end

  @spec ensure_workspace_directory(String.t(), config()) ::
          {:ok, String.t()} | {:error, {:benchmark_setup_error, term()}}
  def ensure_workspace_directory(path, config) do
    with {:ok, canonical} <- canonical_directory(path),
         :ok <- require_within(canonical, config.workspace_root, :workspace_outside_root) do
      {:ok, canonical}
    else
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      {:error, reason} -> setup_error({:invalid_workspace_directory, reason})
    end
  end

  @spec canonical_pair_root(String.t(), config()) ::
          {:ok, String.t()} | {:error, {:benchmark_setup_error, term()}}
  def canonical_pair_root(path, config) do
    with {:ok, canonical} <- canonical_directory(path),
         :ok <- validate_pair_root(canonical, config) do
      {:ok, canonical}
    else
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      {:error, reason} -> setup_error({:invalid_pair_root, reason})
    end
  end

  @spec prepare_execution(String.t(), String.t(), String.t(), String.t(), config()) ::
          {:ok, topology()} | {:error, {:benchmark_setup_error, term()}}
  def prepare_execution(workdir, executor_path, digest, task_id, config)
      when executor_path in ["legacy", "pipeline"] and is_binary(digest) and
             is_binary(task_id) do
    pair_path = Path.dirname(workdir)

    with {:ok, canonical_workdir} <- canonical_directory(workdir),
         :ok <-
           require_within(canonical_workdir, config.workspace_root, :workdir_outside_workspace),
         true <- Path.basename(canonical_workdir) == executor_path,
         {:ok, pair_root} <- canonical_pair_root(pair_path, config),
         true <- Path.dirname(canonical_workdir) == pair_root,
         {:ok, worktree_root} <-
           create_directories(pair_root, ["worktrees", executor_path, digest]),
         {:ok, real_worktree_root} <- SafePath.resolve_real(worktree_root),
         {:ok, ^real_worktree_root} <- SafePath.resolve_within(real_worktree_root, pair_root),
         {:ok, artifact_root} <- artifact_task_root(config.artifact_root, task_id) do
      {:ok,
       %{
         artifact_root: artifact_root,
         pair_root: pair_root,
         workdir: canonical_workdir,
         worktree_root: real_worktree_root
       }}
    else
      false -> setup_error(:invalid_request_workdir_topology)
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      _other -> setup_error(:invalid_execution_topology)
    end
  end

  def prepare_execution(_workdir, _executor_path, _digest, _task_id, _config),
    do: setup_error(:invalid_execution_topology)

  defp configured_directory(key) do
    case Application.fetch_env(@app, key) do
      {:ok, path} when is_binary(path) ->
        case canonical_directory(path) do
          {:ok, "/"} -> setup_error({key, :root_not_allowed})
          {:ok, canonical} -> {:ok, canonical}
          {:error, reason} -> setup_error({key, reason})
        end

      {:ok, _invalid} ->
        setup_error({key, :expected_directory_path})

      :error ->
        setup_error({key, :not_configured})
    end
  end

  defp configured_timeout(key, min, max) do
    case Application.fetch_env(@app, key) do
      {:ok, timeout}
      when is_integer(timeout) and timeout >= min and timeout <= max ->
        {:ok, timeout}

      {:ok, _invalid} ->
        setup_error({key, :out_of_bounds})

      :error ->
        setup_error({key, :not_configured})
    end
  end

  defp orchestrator_roots(:repo) do
    case OrchestratorConfig.coding_repo_roots() do
      {:ok, roots} -> canonical_roots(roots, :coding_repo_roots)
      {:error, reason} -> setup_error({:coding_repo_roots_unavailable, reason})
    end
  end

  defp orchestrator_roots(:worktree) do
    case OrchestratorConfig.coding_worktree_roots() do
      {:ok, roots} -> canonical_roots(roots, :coding_worktree_roots)
      {:error, reason} -> setup_error({:coding_worktree_roots_unavailable, reason})
    end
  end

  defp canonical_roots(roots, field) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case canonical_directory(root) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        {:error, reason} -> {:halt, setup_error({field, reason})}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, Enum.reverse(canonical)}
      {:error, _reason} = error -> error
    end
  end

  defp require_admitted(workspace_root, roots, field) do
    if Enum.any?(roots, &path_within?(workspace_root, &1)),
      do: :ok,
      else: setup_error({field, :workspace_not_admitted})
  end

  defp require_distinct_child(path, root) do
    cond do
      path == root -> setup_error(:artifact_root_must_be_distinct)
      path_within?(path, root) -> :ok
      true -> setup_error(:artifact_root_outside_workspace)
    end
  end

  defp validate_pair_root(path, config) do
    cond do
      path == config.workspace_root ->
        setup_error(:invalid_pair_root)

      not path_within?(path, config.workspace_root) ->
        setup_error(:pair_root_outside_workspace)

      roots_overlap?(path, config.artifact_root) ->
        setup_error(:pair_root_overlaps_artifact_root)

      true ->
        :ok
    end
  end

  defp require_within(path, root, reason) do
    if path_within?(path, root), do: :ok, else: setup_error(reason)
  end

  defp artifact_task_root(artifact_root, task_id) do
    digest = sha256(task_id)

    case SafePath.safe_join(artifact_root, "task-" <> digest) do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> setup_error({:invalid_artifact_task_root, reason})
    end
  end

  defp create_directories(root, components) do
    Enum.reduce_while(components, {:ok, root}, fn component, {:ok, parent} ->
      child = Path.join(parent, component)

      case ensure_directory(child) do
        :ok -> {:cont, {:ok, child}}
        {:error, reason} -> {:halt, setup_error({:worktree_root_create_failed, reason})}
      end
    end)
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_existing_path}
      {:error, :enoent} -> File.mkdir(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_directory(path) when is_binary(path) do
    with :ok <- SafePath.validate(path),
         {:ok, real} <- SafePath.resolve_real(path),
         true <- File.dir?(real) do
      {:ok, real}
    else
      _other -> {:error, :directory_not_found}
    end
  end

  defp canonical_directory(_path), do: {:error, :expected_directory_path}

  defp path_within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp roots_overlap?(left, right), do: path_within?(left, right) or path_within?(right, left)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp setup_error(reason), do: {:error, {:benchmark_setup_error, reason}}
end
