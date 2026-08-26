defmodule Arbor.Shell.OciHostEnvCore do
  @moduledoc """
  Pure admission of the host-side rootless Podman CLI environment.

  The child environment stays deny-by-default (`clear_env: true`). Only
  `HOME`, `XDG_RUNTIME_DIR`, and `PATH=/usr/bin:/bin` are admitted, sourced
  from already-collected runtime evidence — never from a caller envelope.
  Performs no IO.
  """

  import Bitwise

  @path "/usr/bin:/bin"
  @allowed_env_keys MapSet.new(["HOME", "XDG_RUNTIME_DIR", "PATH"])
  @max_path_bytes 4_096
  @max_mountinfo_bytes 1_048_576
  @max_mountinfo_lines 4_096

  @logical_keys [:home, :xdg_runtime_dir, :euid, :home_pin, :xdg]
  @allowed_keys MapSet.new(@logical_keys ++ Enum.map(@logical_keys, &Atom.to_string/1))

  @xdg_stat_keys MapSet.new([:type, :uid, :mode, :fstype, "type", "uid", "mode", "fstype"])

  @spec path() :: String.t()
  def path, do: @path

  @spec admit(term()) :: {:ok, %{String.t() => String.t()}} | {:error, atom()}
  def admit(evidence) when is_map(evidence) do
    with :ok <- validate_keys(evidence, @allowed_keys, :unsupported_host_env_keys),
         {:ok, home} <- fetch_canonical_path(evidence, :home, :missing_home, :invalid_home),
         :ok <- require_home_pin(evidence),
         {:ok, euid} <- fetch_euid(evidence),
         {:ok, xdg} <-
           fetch_canonical_path(
             evidence,
             :xdg_runtime_dir,
             :missing_xdg_runtime_dir,
             :invalid_xdg_runtime_dir
           ),
         :ok <- require_xdg_path(xdg, euid),
         :ok <- require_xdg_stat(evidence, euid) do
      {:ok,
       %{
         "HOME" => home,
         "XDG_RUNTIME_DIR" => xdg,
         "PATH" => @path
       }}
    end
  end

  def admit(_evidence), do: {:error, :invalid_host_env_evidence}

  @spec require_closed(term()) :: :ok | {:error, atom()}
  def require_closed(env) when is_map(env) do
    keys = Map.keys(env) |> MapSet.new()

    cond do
      keys != @allowed_env_keys ->
        {:error, :invalid_rootless_host_env}

      env["PATH"] != @path ->
        {:error, :invalid_rootless_host_env}

      not valid_env_path?(env["HOME"]) ->
        {:error, :invalid_rootless_host_env}

      not valid_env_path?(env["XDG_RUNTIME_DIR"]) ->
        {:error, :invalid_rootless_host_env}

      true ->
        :ok
    end
  end

  def require_closed(_env), do: {:error, :invalid_rootless_host_env}

  @spec fstype_at(term(), term()) :: {:ok, String.t()} | {:error, atom()}
  def fstype_at(mountinfo, path)
      when is_binary(mountinfo) and is_binary(path) do
    with :ok <- require_bounded(mountinfo, @max_mountinfo_bytes, :mountinfo_too_long),
         :ok <- require_valid_utf8(mountinfo, :invalid_mountinfo),
         {:ok, mounts} <- parse_mountinfo(mountinfo) do
      longest_covering_fstype(mounts, path)
    end
  end

  def fstype_at(_mountinfo, _path), do: {:error, :invalid_mountinfo}

  defp validate_keys(map, allowed, reason) do
    if Enum.any?(Map.keys(map), &(not MapSet.member?(allowed, &1))) do
      {:error, reason}
    else
      :ok
    end
  end

  defp fetch_canonical_path(map, key, missing, invalid) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_binary(value) ->
        if valid_env_path?(value), do: {:ok, value}, else: {:error, invalid}

      _other ->
        {:error, invalid}
    end
  end

  defp valid_env_path?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= @max_path_bytes and
      Path.type(value) == :absolute and not String.contains?(value, <<0>>) and
      not String.contains?(value, ["//", "/./", "/../"]) and
      (value == "/" or not String.ends_with?(value, "/"))
  end

  defp valid_env_path?(_value), do: false

  defp require_home_pin(map) do
    case get_field(map, :home_pin) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      nil -> {:error, :missing_home_pin}
      _other -> {:error, :invalid_home_pin}
    end
  end

  defp fetch_euid(map) do
    case get_field(map, :euid) do
      uid when is_integer(uid) and uid > 0 and uid <= 4_294_967_295 -> {:ok, uid}
      nil -> {:error, :missing_euid}
      _other -> {:error, :invalid_euid}
    end
  end

  defp require_xdg_path(xdg, euid) do
    if xdg == "/run/user/" <> Integer.to_string(euid) do
      :ok
    else
      {:error, :untrusted_xdg_runtime_dir}
    end
  end

  defp require_xdg_stat(map, euid) do
    case get_field(map, :xdg) do
      stat when is_map(stat) ->
        with :ok <- validate_keys(stat, @xdg_stat_keys, :unsupported_xdg_stat_keys),
             :ok <- require_xdg_type(stat),
             :ok <- require_xdg_uid(stat, euid),
             :ok <- require_xdg_mode(stat) do
          require_xdg_fstype(stat)
        end

      nil ->
        {:error, :missing_xdg_stat}

      _other ->
        {:error, :invalid_xdg_stat}
    end
  end

  defp require_xdg_type(stat) do
    case get_field(stat, :type) do
      :directory -> :ok
      _other -> {:error, :untrusted_xdg_runtime_dir}
    end
  end

  defp require_xdg_uid(stat, euid) do
    case get_field(stat, :uid) do
      ^euid -> :ok
      _other -> {:error, :untrusted_xdg_runtime_dir}
    end
  end

  defp require_xdg_mode(stat) do
    case get_field(stat, :mode) do
      mode when is_integer(mode) and mode >= 0 ->
        if (mode &&& 0o077) == 0, do: :ok, else: {:error, :untrusted_xdg_runtime_dir}

      _other ->
        {:error, :untrusted_xdg_runtime_dir}
    end
  end

  defp require_xdg_fstype(stat) do
    case get_field(stat, :fstype) do
      "tmpfs" -> :ok
      _other -> {:error, :xdg_runtime_not_tmpfs}
    end
  end

  defp require_bounded(value, max, reason) do
    if byte_size(value) <= max, do: :ok, else: {:error, reason}
  end

  defp require_valid_utf8(value, reason) do
    if String.valid?(value), do: :ok, else: {:error, reason}
  end

  defp parse_mountinfo(text) do
    lines = String.split(text, "\n", trim: true)

    if length(lines) > @max_mountinfo_lines do
      {:error, :mountinfo_too_long}
    else
      mounts =
        Enum.reduce(lines, [], fn line, acc ->
          case parse_mountinfo_line(line) do
            {:ok, mount} -> [mount | acc]
            :skip -> acc
          end
        end)

      {:ok, Enum.reverse(mounts)}
    end
  end

  defp parse_mountinfo_line(line) do
    case String.split(line, " - ", parts: 2) do
      [left, right] ->
        case {String.split(left), String.split(right)} do
          {[_, _, _, _, mountpoint | _], [fstype | _]}
          when mountpoint != "" and fstype != "" ->
            {:ok, {unescape_mount_field(mountpoint), fstype}}

          _other ->
            :skip
        end

      _other ->
        :skip
    end
  end

  defp unescape_mount_field(field) when is_binary(field) do
    String.replace(field, ["\\040", "\\011", "\\012", "\\134"], fn
      "\\040" -> " "
      "\\011" -> "\t"
      "\\012" -> "\n"
      "\\134" -> "\\"
    end)
  end

  defp longest_covering_fstype(mounts, path) do
    covering =
      Enum.reduce(mounts, nil, fn {mountpoint, fstype}, best ->
        if covers_path?(mountpoint, path) do
          case best do
            {best_size, _} when best_size >= byte_size(mountpoint) -> best
            _other -> {byte_size(mountpoint), fstype}
          end
        else
          best
        end
      end)

    case covering do
      {_size, fstype} -> {:ok, fstype}
      nil -> {:error, :xdg_runtime_mount_unknown}
    end
  end

  defp covers_path?(mountpoint, path) do
    path == mountpoint or
      (mountpoint == "/" and String.starts_with?(path, "/")) or
      String.starts_with?(path, mountpoint <> "/")
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
