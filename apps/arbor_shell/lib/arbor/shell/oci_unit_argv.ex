defmodule Arbor.Shell.OciUnitArgv do
  @moduledoc false

  # Launcher-side review of OCI/Podman unit argv, mirrored in
  # arbor_shell_launcher.c (`reviewed_oci_unit`). Elixir review is defense
  # in depth before PortSession; the native launcher is the enforcing gate.

  alias Arbor.Shell.SpawnCapableArgvLimits

  @max_arg_bytes 4_096
  @guest_destinations MapSet.new([
                        "/workspace",
                        "/arbor/home",
                        "/arbor/build",
                        "/arbor/deps",
                        "/arbor/validation/runner",
                        "/arbor/validation/result",
                        "/arbor/bin"
                      ])
  @read_only_guest_destinations MapSet.new([
                                  "/arbor/validation/runner",
                                  "/arbor/bin"
                                ])
  @env_keys MapSet.new([
              "HOME",
              "TMPDIR",
              "MIX_BUILD_PATH",
              "MIX_DEPS_PATH",
              "MIX_HOME",
              "MIX_ARCHIVES",
              "ELIXIR_MAKE_CACHE_DIR",
              "ARBOR_MIX_CONTAINED",
              "ARBOR_SOURCE_INVENTORY_PATH",
              "ARBOR_ERLANG_ROOT",
              "ARBOR_ELIXIR_ROOT",
              "MIX_ENV"
            ])
  @name_re ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @digest_re ~r/\Asha256:[0-9a-f]{64}\z/

  @spec review(term()) :: :ok | {:error, :unreviewed_oci_unit_command}
  def review(args) when is_list(args) do
    if Enum.all?(args, &valid_token?/1) and reviewed_command?(args) do
      :ok
    else
      {:error, :unreviewed_oci_unit_command}
    end
  end

  def review(_args), do: {:error, :unreviewed_oci_unit_command}

  @spec review_unit_name(term()) :: :ok | {:error, :unreviewed_oci_unit_command}
  def review_unit_name(name) when is_binary(name) do
    if unit_name?(name), do: :ok, else: {:error, :unreviewed_oci_unit_command}
  end

  def review_unit_name(_name), do: {:error, :unreviewed_oci_unit_command}

  defp reviewed_command?(["ps", "-a", "--format", "json"]), do: true
  defp reviewed_command?(["start", "--attach", name]), do: unit_name?(name)
  defp reviewed_command?(["kill", "--signal", "KILL", name]), do: unit_name?(name)
  defp reviewed_command?(["rm", "--force", name]), do: unit_name?(name)
  defp reviewed_command?(["create" | rest]), do: reviewed_create?(rest)
  defp reviewed_command?(_args), do: false

  defp reviewed_create?(args) do
    with {:ok, rest} <- take_pair(args, "--name", &unit_name?/1),
         {:ok, rest} <- take_pair(rest, "--platform", &platform?/1),
         {:ok, rest} <- take_pair(rest, "--pull", &(&1 == "never")),
         {:ok, rest} <- take_pair(rest, "--network", &(&1 == "none")),
         {:ok, rest} <- take_flag(rest, "--read-only"),
         {:ok, rest} <- take_pair(rest, "--cap-drop", &(&1 == "ALL")),
         {:ok, rest} <- take_pair(rest, "--userns", &(&1 == "keep-id")),
         {:ok, rest} <- take_pair(rest, "--cpus", &(&1 in ["1", "4"])),
         {:ok, rest} <- take_pair(rest, "--memory", &(&1 in ["2g", "4g"])),
         {:ok, rest} <- take_pair(rest, "--pids-limit", &(&1 in ["512", "2048"])),
         {:ok, rest} <- take_mounts(rest),
         {:ok, rest} <- take_pair(rest, "--tmpfs", &(&1 == "/tmp:rw,mode=1777")),
         {:ok, rest} <- take_pair(rest, "--workdir", &(&1 == "/workspace")),
         {:ok, rest} <- take_envs(rest),
         {:ok, rest} <- take_pair(rest, "--entrypoint", &(&1 == "/arbor/bin/mix")),
         [image | command_args] <- rest,
         true <- Regex.match?(@digest_re, image),
         true <- length(command_args) <= SpawnCapableArgvLimits.max_command_args(),
         true <- Enum.all?(command_args, &valid_token?/1) do
      true
    else
      _other -> false
    end
  end

  defp take_pair([flag, value | rest], flag, pred) when is_function(pred, 1) do
    if pred.(value), do: {:ok, rest}, else: :error
  end

  defp take_pair(_args, _flag, _pred), do: :error

  defp take_flag([flag | rest], flag), do: {:ok, rest}
  defp take_flag(_args, _flag), do: :error

  defp take_mounts(["--mount", spec | rest]) do
    if mount_spec?(spec), do: take_mounts(rest), else: :error
  end

  defp take_mounts(rest), do: {:ok, rest}

  defp take_envs(["--env", pair | rest]) do
    if env_pair?(pair), do: take_envs(rest), else: :error
  end

  defp take_envs(rest), do: {:ok, rest}

  defp mount_spec?(spec) when is_binary(spec) do
    case spec do
      "type=bind,source=" <> rest ->
        case String.split(rest, ",destination=", parts: 2) do
          [source, dest_and_maybe_ro] ->
            {dest, read_only?} =
              case String.split(dest_and_maybe_ro, ",ro=true", parts: 2) do
                [destination, ""] -> {destination, true}
                [only] -> {only, false}
                _other -> {dest_and_maybe_ro, false}
              end

            MapSet.member?(@guest_destinations, dest) and absolute_path?(source) and
              (read_only? or not MapSet.member?(@read_only_guest_destinations, dest))

          _other ->
            false
        end

      _other ->
        false
    end
  end

  defp mount_spec?(_spec), do: false

  defp env_pair?(pair) when is_binary(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] ->
        MapSet.member?(@env_keys, key) and env_value?(key, value)

      _other ->
        false
    end
  end

  defp env_pair?(_pair), do: false

  defp env_value?("ARBOR_MIX_CONTAINED", "1"), do: true
  defp env_value?("MIX_ENV", value), do: value in ["dev", "test", "prod"]

  defp env_value?(_key, value),
    do: absolute_path?(value) or MapSet.member?(@guest_destinations, value)

  defp platform?(value), do: value in ["linux/amd64", "linux/arm64"]

  defp unit_name?(name) when is_binary(name) do
    byte_size(name) >= 2 and byte_size(name) <= 63 and Regex.match?(@name_re, name)
  end

  defp unit_name?(_name), do: false

  defp absolute_path?(path) when is_binary(path) do
    valid_token?(path) and String.starts_with?(path, "/") and not String.contains?(path, "//") and
      not String.contains?(path, ",") and not String.contains?(path, "=") and
      not dotdot_segment?(path)
  end

  defp absolute_path?(_path), do: false

  defp dotdot_segment?(path) do
    path == ".." or String.starts_with?(path, "../") or String.contains?(path, "/../") or
      String.ends_with?(path, "/..")
  end

  defp valid_token?(token) when is_binary(token) do
    token != "" and byte_size(token) <= @max_arg_bytes and not String.contains?(token, <<0>>)
  end

  defp valid_token?(_token), do: false
end
