defmodule Arbor.Shell.OciHostEnv do
  @moduledoc false

  # Resolves the closed host-side environment rootless Podman needs to see
  # its own storage. Values come from the Arbor service process, never from
  # a caller envelope. HOME is operator-owned-pinned; XDG_RUNTIME_DIR must
  # be the euid's `/run/user/<uid>` tmpfs directory.

  alias Arbor.Shell.OciHostEnvCore
  alias Arbor.Shell.TrustedPath

  @mountinfo_path "/proc/self/mountinfo"
  @max_mountinfo_bytes 1_048_576

  @spec resolve() :: {:ok, %{String.t() => String.t()}} | {:error, atom()}
  def resolve do
    with {:ok, home} <- fetch_process_env("HOME", :missing_home),
         {:ok, xdg} <- fetch_process_env("XDG_RUNTIME_DIR", :missing_xdg_runtime_dir),
         {:ok, home} <- TrustedPath.canonicalize_absolute(home),
         {:ok, xdg} <- TrustedPath.canonicalize_absolute(xdg),
         {:ok, home_identity} <- pin_home(home),
         {:ok, xdg_stat} <- lstat_directory(xdg),
         {:ok, fstype} <- mount_fstype(xdg) do
      OciHostEnvCore.admit(%{
        home: home,
        xdg_runtime_dir: xdg,
        euid: home_identity.uid,
        home_pin: :ok,
        xdg: %{
          type: xdg_stat.type,
          uid: xdg_stat.uid,
          mode: xdg_stat.mode,
          fstype: fstype
        }
      })
    end
  end

  defp fetch_process_env(name, missing) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, missing}
    end
  end

  defp pin_home(path) do
    case TrustedPath.pin_operator_owned_directory(path) do
      {:ok, identity} -> {:ok, identity}
      {:error, :untrusted_path} -> {:error, :untrusted_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lstat_directory(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :xdg_runtime_dir_missing}
      {:error, _reason} -> {:error, :untrusted_xdg_runtime_dir}
    end
  end

  defp mount_fstype(path) do
    with {:ok, contents} <- read_mountinfo() do
      OciHostEnvCore.fstype_at(contents, path)
    end
  end

  defp read_mountinfo do
    case File.read(@mountinfo_path) do
      {:ok, contents} when byte_size(contents) <= @max_mountinfo_bytes ->
        {:ok, contents}

      {:ok, _contents} ->
        {:error, :mountinfo_too_long}

      {:error, :enoent} ->
        {:error, :xdg_runtime_mount_unknown}

      {:error, _reason} ->
        {:error, :xdg_runtime_mount_unknown}
    end
  end
end
