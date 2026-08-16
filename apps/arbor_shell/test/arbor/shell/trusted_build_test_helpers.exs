defmodule Arbor.Shell.TrustedBuildTestHelpers do
  @moduledoc false

  @marker_name ".arbor-tb-fixture-marker"
  @unsafe_roots MapSet.new(["/", "/private", "/tmp", "/var", "/private/tmp"])

  def unique_source_root do
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    Path.join(System.tmp_dir!(), "arbor-tb-src-#{suffix}")
  end

  def capture_handle!(path) when is_binary(path) do
    {:ok, stat} = File.lstat(path, time: :posix)
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    File.write!(Path.join(path, @marker_name), token)

    %{
      root: path,
      device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      marker: token
    }
  end

  def handle_for_owned!(%{path: path} = identity) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    File.write!(Path.join(path, @marker_name), token)

    %{
      root: identity.path,
      device: identity.device,
      minor_device: identity.minor_device,
      inode: identity.inode,
      marker: token
    }
  end

  def rm_fixture!(%{root: root} = handle), do: rm_fixture!(root, handle)

  def rm_fixture!(target, handle) when is_binary(target) and is_map(handle) do
    case authorize_fixture_cleanup(target, handle) do
      :ok ->
        case File.rm_rf(target) do
          {:ok, _removed} -> :ok
          {:error, reason, _files} -> {:error, {:rm_rf_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stop_retained_worker(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      case DynamicSupervisor.terminate_child(
             Arbor.Shell.TrustedBuild.LeaseSupervisor,
             pid
           ) do
        :ok ->
          :ok

        {:error, :not_found} ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :shutdown, 5_000)
            catch
              :exit, {:noproc, _} -> :already_down
              :exit, {:normal, _} -> :ok
              :exit, {:shutdown, _} -> :ok
              :exit, _reason -> :stop_exit
            end
          else
            :already_down
          end

        {:error, _reason} ->
          :supervisor_stop_failed
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 ->
          {:error, :retained_worker_stop_timeout}
      end
    else
      :ok
    end
  end

  def stop_retained_worker(_pid), do: :ok

  def plant_fixed_overlay!(owned_path) when is_binary(owned_path) do
    desc = Arbor.Shell.trusted_build_native_overlay_descriptor()
    dest = Path.join(owned_path, desc["staging_rel"])
    File.mkdir_p!(Path.dirname(dest))

    case overlay_source_bytes(desc) do
      {:ok, bytes} ->
        File.write!(dest, bytes)
        File.chmod!(dest, 0o644)
        :ok

      {:error, reason} ->
        raise "trusted-build overlay unavailable: #{inspect(reason)}"
    end
  end

  def overlay_source_bytes(desc \\ Arbor.Shell.trusted_build_native_overlay_descriptor()) do
    desc
    |> overlay_candidates()
    |> Enum.find_value({:error, :overlay_bytes_unavailable}, fn path ->
      case File.read(path) do
        {:ok, bytes} ->
          digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

          if byte_size(bytes) == desc["size"] and digest == desc["sha256"] do
            {:ok, bytes}
          else
            false
          end

        {:error, _reason} ->
          false
      end
    end)
  end

  def plant_release_cookie!(build_path) when is_binary(build_path) do
    path = Path.join(build_path, "rel/arbor_trust/releases/COOKIE")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "cookie\n")
    File.chmod!(path, 0o644)
    :ok
  end

  def after_deps_get!(lease) do
    assert_stage = Arbor.Shell.stage_trusted_build_native(lease)
    match?({:ok, _}, assert_stage) || raise "stage failed: #{inspect(assert_stage)}"
    assert_inv = Arbor.Shell.inventory_trusted_build_deps(lease)
    match?({:ok, _}, assert_inv) || raise "deps inventory failed: #{inspect(assert_inv)}"
    :ok
  end

  defp overlay_candidates(desc) do
    repo = Path.expand("../../../../..", __DIR__)
    deps = System.get_env("MIX_DEPS_PATH") || Path.join(repo, "deps")

    [
      Path.join(deps, "sqlite_vec/priv/0.1.5/vec0.dylib"),
      Path.join(repo, desc["logical_path"]),
      Path.join(repo, Path.join("apps/arbor_commands/priv/packaging", desc["staging_rel"]))
    ]
  end

  def authorize_fixture_cleanup(target, handle) when is_binary(target) and is_map(handle) do
    cond do
      target != handle.root ->
        {:error, :cleanup_target_mismatch}

      unsafe_cleanup_root?(handle.root) ->
        {:error, :unsafe_cleanup_root}

      true ->
        verify_handle_identity(handle)
    end
  end

  def unsafe_cleanup_root?(path) when is_binary(path) do
    tmp = System.tmp_dir!()

    path == tmp or path == Path.dirname(tmp) or path in @unsafe_roots or
      ancestor_of_root?(path, tmp)
  end

  def ancestor_of_root?(candidate, root) do
    candidate_segs = Path.split(candidate)
    root_segs = Path.split(root)
    candidate_segs != root_segs and List.starts_with?(root_segs, candidate_segs)
  end

  defp verify_handle_identity(handle) do
    case File.lstat(handle.root, time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: device,
         minor_device: minor,
         inode: inode
       }}
      when device == handle.device and minor == handle.minor_device and inode == handle.inode ->
        verify_marker(handle)

      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :cleanup_identity_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_marker(handle) do
    marker_path = Path.join(handle.root, @marker_name)

    case File.read(marker_path) do
      {:ok, token} when token == handle.marker -> :ok
      {:ok, _other} -> {:error, :cleanup_marker_mismatch}
      {:error, _reason} -> {:error, :cleanup_marker_missing}
    end
  end
end
