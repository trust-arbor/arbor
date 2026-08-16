defmodule Arbor.Shell.TrustedBuildTestHelpers do
  @moduledoc false

  @marker_name ".arbor-tb-fixture-marker"
  @unsafe_roots MapSet.new(["/", "/private", "/tmp", "/var", "/private/tmp"])

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
