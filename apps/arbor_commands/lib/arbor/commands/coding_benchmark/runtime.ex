defmodule Arbor.Commands.CodingBenchmark.Runtime do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator

  @app :arbor_commands
  @workspace_root_key :coding_benchmark_workspace_root
  @artifact_root_key :coding_benchmark_artifact_root
  @timeout_key :coding_benchmark_execution_timeout_ms
  @fixture_setup_timeout_key :coding_benchmark_fixture_setup_timeout_ms
  @cancellation_timeout_key :coding_benchmark_cancellation_timeout_ms
  @min_timeout_ms 10
  @max_timeout_ms 86_400_000
  @max_cancellation_timeout_ms 30_000
  @default_fixture_setup_timeout_ms 300_000
  @broad_root_paths ["/", Path.expand("~")]
  @lease_schema "arbor.coding_benchmark.artifact_lease.v1"
  @lease_directory ".benchmark-leases"

  @type config :: %{
          workspace_root: String.t(),
          artifact_root: String.t(),
          execution_timeout_ms: pos_integer(),
          fixture_setup_timeout_ms: pos_integer(),
          cancellation_timeout_ms: pos_integer()
        }

  @type topology :: %{
          workdir: String.t(),
          pair_root: String.t(),
          worktree_root: String.t(),
          artifact_root: String.t(),
          artifact_lease: String.t()
        }

  @spec load() :: {:ok, config()} | {:error, {:benchmark_setup_error, term()}}
  def load do
    with {:ok, workspace_root} <- configured_directory(@workspace_root_key),
         {:ok, artifact_root} <- configured_directory(@artifact_root_key),
         :ok <- require_distinct_child(artifact_root, workspace_root),
         {:ok, timeout} <-
           configured_timeout(@timeout_key, @min_timeout_ms, @max_timeout_ms),
         {:ok, fixture_setup_timeout} <-
           configured_timeout_or_default(
             @fixture_setup_timeout_key,
             @min_timeout_ms,
             @max_timeout_ms,
             @default_fixture_setup_timeout_ms
           ),
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
         fixture_setup_timeout_ms: fixture_setup_timeout,
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
         {:ok, logs_root} <- canonical_directory(Orchestrator.coding_pipeline_logs_root()),
         true <- logs_root == config.artifact_root do
      :ok
    else
      false -> setup_error(:coding_pipeline_logs_root_mismatch)
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      {:error, reason} -> setup_error(reason)
    end
  end

  @doc "Validate a caller-provided benchmark trust root at a command boundary."
  @spec validate_trusted_root(term()) ::
          {:ok, String.t()} | {:error, {:benchmark_setup_error, term()}}
  def validate_trusted_root(path) do
    with {:ok, canonical} <- canonical_directory(path),
         :ok <- reject_broad_root(canonical) do
      {:ok, canonical}
    else
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      {:error, reason} -> setup_error(reason)
    end
  end

  @doc "Reject artifact roots that overlap any declared fixture repository."
  @spec ensure_artifact_root_disjoint(String.t(), String.t(), [String.t()]) ::
          :ok | {:error, {:benchmark_setup_error, term()}}
  def ensure_artifact_root_disjoint(artifact_root, fixture_root, fixture_paths)
      when is_binary(artifact_root) and is_binary(fixture_root) and is_list(fixture_paths) do
    with {:ok, artifact} <- canonical_directory(artifact_root),
         {:ok, fixtures} <- canonical_directory(fixture_root),
         :ok <- reject_broad_root(artifact),
         :ok <- reject_fixture_overlap(artifact, fixtures, fixture_paths) do
      :ok
    else
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      {:error, reason} -> setup_error(reason)
    end
  end

  def ensure_artifact_root_disjoint(_artifact_root, _fixture_root, _fixture_paths),
    do: setup_error(:invalid_fixture_root)

  @spec ensure_workspace_directory(String.t(), config()) ::
          {:ok, String.t()} | {:error, {:benchmark_setup_error, term()}}
  def ensure_workspace_directory(path, config) do
    with {:ok, canonical} <- canonical_directory(path),
         :ok <- reject_broad_root(canonical),
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
         artifact_lease = artifact_lease(task_id, canonical_workdir),
         {:ok, artifact_root} <-
           artifact_task_root(config.artifact_root, task_id, artifact_lease) do
      {:ok,
       %{
         artifact_lease: artifact_lease,
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

  @spec preview_execution(String.t(), String.t(), String.t(), String.t(), config()) ::
          {:ok, topology()} | {:error, {:benchmark_setup_error, term()}}
  def preview_execution(workdir, executor_path, digest, task_id, config)
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
           SafePath.safe_join(pair_root, Path.join(["worktrees", executor_path, digest])),
         {:ok, artifact_root} <-
           SafePath.safe_join(config.artifact_root, "task-" <> sha256(task_id)) do
      {:ok,
       %{
         artifact_lease: artifact_lease(task_id, canonical_workdir),
         artifact_root: artifact_root,
         pair_root: pair_root,
         workdir: canonical_workdir,
         worktree_root: worktree_root
       }}
    else
      false -> setup_error(:invalid_request_workdir_topology)
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      _other -> setup_error(:invalid_execution_topology)
    end
  end

  def preview_execution(_workdir, _executor_path, _digest, _task_id, _config),
    do: setup_error(:invalid_execution_topology)

  defp configured_directory(key) do
    case Application.fetch_env(@app, key) do
      {:ok, path} when is_binary(path) ->
        case canonical_directory(path) do
          {:ok, canonical} ->
            with :ok <- reject_broad_root(canonical) do
              {:ok, canonical}
            else
              {:error, {:benchmark_setup_error, reason}} ->
                setup_error({key, reason})
            end

          {:error, reason} ->
            setup_error({key, reason})
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

  defp configured_timeout_or_default(key, min, max, default) do
    case Application.fetch_env(@app, key) do
      {:ok, timeout} when is_integer(timeout) and timeout >= min and timeout <= max ->
        {:ok, timeout}

      {:ok, _invalid} ->
        setup_error({key, :out_of_bounds})

      :error ->
        {:ok, default}
    end
  end

  defp orchestrator_roots(:repo) do
    case Orchestrator.coding_repo_roots() do
      {:ok, roots} -> canonical_roots(roots, :coding_repo_roots)
      {:error, reason} -> setup_error({:coding_repo_roots_unavailable, reason})
    end
  end

  defp orchestrator_roots(:worktree) do
    case Orchestrator.coding_worktree_roots() do
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

  @doc "Return true only when the external control record owns the exact artifact root inode."
  @spec artifact_lease_owned?(String.t(), String.t(), config()) :: boolean()
  def artifact_lease_owned?(path, lease, config)
      when is_binary(path) and is_binary(lease) do
    artifact_lease_state(path, lease, config) == :owned
  end

  def artifact_lease_owned?(_path, _lease, _config), do: false

  @doc "Classify lease ownership without mutating either the root or control record."
  @spec artifact_lease_state(String.t(), String.t(), config()) ::
          :owned | :foreign | :absent | :corrupt | :unmanaged
  def artifact_lease_state(path, lease, config)
      when is_binary(path) and is_binary(lease) do
    with {:ok, control_path} <- lease_control_path(path, config) do
      case File.lstat(control_path) do
        {:error, :enoent} -> if File.exists?(path), do: :unmanaged, else: :absent
        {:ok, %{type: :regular}} -> classify_lease_record(control_path, path, lease)
        _other -> :corrupt
      end
    else
      _other -> :corrupt
    end
  end

  def artifact_lease_state(_path, _lease, _config), do: :corrupt

  @doc "Release an exact benchmark artifact lease without trusting worker-writable metadata."
  @spec release_artifact_root(String.t(), String.t(), config()) :: :ok | {:error, term()}
  def release_artifact_root(path, lease, config)
      when is_binary(path) and is_binary(lease) do
    quarantine = Path.join(config.artifact_root, ".release-" <> sha256(lease))

    with {:ok, record} <- owned_lease_record(path, lease, config),
         {:ok, control_path} <- lease_control_path(path, config),
         {:error, :enoent} <- File.lstat(quarantine),
         :ok <- File.rename(path, quarantine),
         {:ok, stat} <- File.lstat(quarantine),
         true <- same_root_identity?(stat, record),
         {:ok, _removed} <- File.rm_rf(quarantine),
         :ok <- remove_owned_control(control_path, lease),
         :ok <- remove_empty_lease_directory(config) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :artifact_root_identity_changed}
      _other -> {:error, :artifact_release_failed}
    end
  end

  def release_artifact_root(_path, _lease, _config),
    do: {:error, :artifact_lease_not_owned}

  defp artifact_task_root(artifact_root, task_id, lease) do
    digest = sha256(task_id)

    with {:ok, root} <- SafePath.safe_join(artifact_root, "task-" <> digest),
         {:ok, control_path} <- lease_control_path(root, %{artifact_root: artifact_root}),
         :ok <- ensure_lease_directory(artifact_root),
         {:ok, control_identity} <- create_lease_control(control_path, lease) do
      finish_artifact_allocation(root, control_path, control_identity, lease, artifact_root)
    else
      {:error, {:benchmark_setup_error, _reason}} = error -> error
      {:error, reason} -> setup_error({:invalid_artifact_task_root, reason})
      false -> setup_error({:invalid_artifact_task_root, :outside_artifact_root})
      _other -> setup_error({:invalid_artifact_task_root, :revalidation_failed})
    end
  end

  defp finish_artifact_allocation(root, control_path, control_identity, lease, artifact_root) do
    case create_exclusive_artifact_root(root) do
      {:ok, identity} ->
        emit_artifact_root_allocated(root, control_path)

        result =
          with :ok <- write_lease_record(control_path, lease, root, identity),
               {:ok, real_root} <- SafePath.resolve_real(root),
               {:ok, ^real_root} <- SafePath.resolve_within(real_root, artifact_root),
               true <- Path.dirname(real_root) == artifact_root do
            {:ok, real_root}
          else
            false -> setup_error({:invalid_artifact_task_root, :outside_artifact_root})
            {:error, {:benchmark_setup_error, _reason}} = error -> error
            {:error, reason} -> setup_error({:invalid_artifact_task_root, reason})
            _other -> setup_error({:invalid_artifact_task_root, :revalidation_failed})
          end

        allocation_result(
          result,
          root,
          identity,
          control_path,
          control_identity,
          lease,
          artifact_root
        )

      {:error, _reason} = error ->
        allocation_result(
          error,
          nil,
          nil,
          control_path,
          control_identity,
          lease,
          artifact_root
        )
    end
  end

  defp emit_artifact_root_allocated(root, control_path) do
    :telemetry.execute(
      [:arbor, :commands, :coding_benchmark, :artifact_root_allocated],
      %{count: 1},
      %{control_path: control_path, root: root}
    )

    :ok
  end

  defp allocation_result(
         {:ok, _root} = success,
         _path,
         _identity,
         _control,
         _control_identity,
         _lease,
         _artifact
       ),
       do: success

  defp allocation_result(
         error,
         root,
         identity,
         control_path,
         control_identity,
         lease,
         artifact_root
       ) do
    case rollback_allocation(
           root,
           identity,
           control_path,
           control_identity,
           lease,
           artifact_root
         ) do
      :ok ->
        error

      {:error, rollback_reason} ->
        setup_error({:artifact_allocation_rollback_failed, rollback_reason})
    end
  end

  defp create_lease_control(path, lease) do
    content = Jason.encode!(%{"lease" => lease, "state" => "allocating"})

    case File.open(path, [:write, :binary, :exclusive], fn io ->
           with {:ok, info} <- :file.read_file_info(io, time: :posix),
                stat = File.Stat.from_record(info),
                true <- stat.type == :regular,
                identity = root_identity(stat),
                :ok <- IO.binwrite(io, content) do
             {:ok, identity}
           else
             _other -> {:error, :control_file_attestation_failed}
           end
         end) do
      {:ok, {:ok, identity}} ->
        {:ok, identity}

      {:ok, {:error, reason}} ->
        case File.rm(path) do
          :ok ->
            setup_error({:artifact_lease_control_create_failed, reason})

          {:error, rollback_reason} ->
            setup_error({:artifact_lease_control_rollback_failed, rollback_reason})
        end

      {:error, :eexist} ->
        setup_error(:artifact_task_root_exists)

      {:error, reason} ->
        setup_error({:artifact_lease_control_create_failed, reason})

      _other ->
        setup_error(:artifact_lease_control_create_failed)
    end
  end

  defp create_exclusive_artifact_root(path) do
    case File.mkdir(path) do
      :ok ->
        case File.lstat(path) do
          {:ok, %{type: :directory} = stat} ->
            {:ok, root_identity(stat)}

          {:ok, _stat} ->
            rollback_unattested_artifact_root(path, :unsafe_artifact_task_root)

          {:error, reason} ->
            rollback_unattested_artifact_root(path, {:artifact_task_root_lstat_failed, reason})
        end

      {:error, :eexist} ->
        setup_error(:artifact_task_root_exists)

      {:error, reason} ->
        setup_error({:artifact_task_root_create_failed, reason})
    end
  end

  defp rollback_unattested_artifact_root(path, reason) do
    case File.rmdir(path) do
      :ok ->
        setup_error(reason)

      {:error, rollback_reason} ->
        setup_error({:artifact_root_rollback_failed, reason, rollback_reason})
    end
  end

  defp write_lease_record(control_path, lease, root, identity) do
    record =
      Map.merge(identity, %{
        "lease" => lease,
        "root" => root,
        "schema" => @lease_schema
      })

    with {:ok, %{type: :regular}} <- File.lstat(control_path),
         {:ok, current} <- File.read(control_path),
         {:ok, %{"lease" => ^lease, "state" => "allocating"}} <- Jason.decode(current),
         {:ok, encoded} <- Jason.encode(record),
         :ok <- File.write(control_path, encoded, [:write, :binary]) do
      :ok
    else
      _other -> setup_error(:artifact_lease_control_write_failed)
    end
  end

  defp owned_lease_record(path, lease, config) do
    with {:ok, ^path} <- SafePath.resolve_within(path, config.artifact_root),
         true <- Path.dirname(path) == config.artifact_root,
         {:ok, control_path} <- lease_control_path(path, config),
         {:ok, %{type: :regular}} <- File.lstat(control_path),
         {:ok, encoded} <- File.read(control_path),
         {:ok, record} <- Jason.decode(encoded),
         true <- valid_lease_record?(record, path, lease),
         {:ok, %{type: :directory} = stat} <- File.lstat(path),
         true <- same_root_identity?(stat, record) do
      {:ok, record}
    else
      _other -> {:error, :artifact_lease_not_owned}
    end
  end

  defp classify_lease_record(control_path, path, lease) do
    with {:ok, encoded} <- File.read(control_path),
         {:ok, record} <- Jason.decode(encoded),
         true <- valid_lease_record_shape?(record, path) do
      cond do
        record["lease"] != lease -> :foreign
        root_matches_record?(path, record) -> :owned
        true -> :corrupt
      end
    else
      _other -> :corrupt
    end
  end

  defp root_matches_record?(path, record) do
    case File.lstat(path) do
      {:ok, %{type: :directory} = stat} -> same_root_identity?(stat, record)
      _other -> false
    end
  end

  defp valid_lease_record?(record, path, lease) do
    valid_lease_record_shape?(record, path) and record["lease"] == lease
  end

  defp valid_lease_record_shape?(record, path) do
    is_map(record) and record["schema"] == @lease_schema and record["root"] == path and
      is_binary(record["lease"]) and
      Enum.all?(
        ~w(inode major_device minor_device),
        &(is_integer(record[&1]) and record[&1] >= 0)
      )
  end

  defp root_identity(stat) do
    %{
      "inode" => stat.inode,
      "major_device" => stat.major_device,
      "minor_device" => stat.minor_device
    }
  end

  defp same_root_identity?(stat, record) do
    stat.type == :directory and stat.inode == record["inode"] and
      stat.major_device == record["major_device"] and
      stat.minor_device == record["minor_device"]
  end

  defp lease_control_path(root, config) do
    with {:ok, directory} <- SafePath.safe_join(config.artifact_root, @lease_directory),
         {:ok, control} <- SafePath.safe_join(directory, Path.basename(root) <> ".json") do
      {:ok, control}
    end
  end

  defp ensure_lease_directory(artifact_root) do
    path = Path.join(artifact_root, @lease_directory)

    with :ok <- ensure_directory(path),
         {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, ^path} <- SafePath.resolve_real(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      _other -> setup_error(:artifact_lease_directory_failed)
    end
  end

  defp rollback_allocation(
         root,
         identity,
         control_path,
         control_identity,
         _lease,
         artifact_root
       ) do
    case rollback_owned_empty_root(root, identity) do
      :ok ->
        with :ok <- remove_control_identity(control_path, control_identity),
             :ok <- remove_empty_lease_directory(%{artifact_root: artifact_root}) do
          :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp remove_control_identity(control_path, identity) do
    with {:ok, stat} <- File.lstat(control_path),
         true <- stat.type == :regular and same_file_identity?(stat, identity),
         :ok <- File.rm(control_path) do
      :ok
    else
      _other -> {:error, :artifact_lease_control_rollback_failed}
    end
  end

  defp rollback_owned_empty_root(nil, nil), do: :ok

  defp rollback_owned_empty_root(root, identity) do
    with {:ok, stat} <- File.lstat(root),
         true <- same_root_identity?(stat, identity),
         :ok <- File.rmdir(root) do
      :ok
    else
      _other -> {:error, :artifact_root_rollback_failed}
    end
  end

  defp remove_owned_control(control_path, lease) do
    with {:ok, %{type: :regular}} <- File.lstat(control_path),
         {:ok, encoded} <- File.read(control_path),
         {:ok, %{"lease" => ^lease}} <- Jason.decode(encoded),
         :ok <- File.rm(control_path) do
      :ok
    else
      _other -> {:error, :artifact_lease_control_remove_failed}
    end
  end

  defp same_file_identity?(stat, identity) do
    stat.inode == identity["inode"] and stat.major_device == identity["major_device"] and
      stat.minor_device == identity["minor_device"]
  end

  defp remove_empty_lease_directory(config) do
    path = Path.join(config.artifact_root, @lease_directory)

    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} when reason in [:enotempty, :eexist] -> :ok
      {:error, reason} -> {:error, {:artifact_lease_directory_remove_failed, reason}}
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
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, :unsafe_existing_path}

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            case File.lstat(path) do
              {:ok, %{type: :directory}} -> :ok
              {:ok, _stat} -> {:error, :unsafe_existing_path}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
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

  defp reject_broad_root(path) do
    system_temp =
      case SafePath.resolve_real(System.tmp_dir!()) do
        {:ok, canonical} -> canonical
        _other -> Path.expand(System.tmp_dir!())
      end

    if path in @broad_root_paths or path == system_temp or path == File.cwd!() do
      setup_error(:broad_trusted_root)
    else
      :ok
    end
  end

  defp reject_fixture_overlap(artifact, fixture_root, fixture_paths) do
    Enum.reduce_while(fixture_paths, :ok, fn fixture_path, :ok ->
      with {:ok, lexical} <- SafePath.safe_join(fixture_root, fixture_path),
           {:ok, fixture} <- canonical_directory(lexical) do
        if roots_overlap?(artifact, fixture),
          do: {:halt, setup_error(:artifact_root_overlaps_fixture)},
          else: {:cont, :ok}
      else
        _other -> {:halt, setup_error(:fixture_not_found)}
      end
    end)
  end

  defp path_within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp roots_overlap?(left, right), do: path_within?(left, right) or path_within?(right, left)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp artifact_lease(task_id, workdir), do: sha256(task_id <> <<0>> <> workdir)

  defp setup_error(reason), do: {:error, {:benchmark_setup_error, reason}}
end
