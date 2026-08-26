defmodule Arbor.Shell.OciPlanCore do
  @moduledoc """
  Pure OCI/Podman request validation and immutable argv planning.

  Admits a closed request and returns create/start/cleanup argv as data.
  Performs no IO, process execution, filesystem access, or config reads.

  Execution image identity is digest-only (`sha256:` + 64 lowercase hex).
  Tags, registry names, and provisioning refs (`docker.io/...@sha256:...`)
  are rejected here — those belong in policy, not create argv. Create always
  emits `--pull never` and `--network none`.
  """

  alias Arbor.Shell.SpawnCapableArgvLimits

  @runtime_executable "/usr/bin/podman"
  @allowed_platforms MapSet.new(["linux/amd64", "linux/arm64"])

  @default_resource_profile :standard
  @resource_profiles %{
    standard: %{cpus: "1", memory: "2g", pids: "512"},
    intensive: %{cpus: "4", memory: "4g", pids: "2048"}
  }

  @guest_workdir "/workspace"
  @guest_mix_wrapper_dir "/arbor/bin"
  @guest_mix_wrapper "/arbor/bin/mix"
  @guest_erlang_root "/usr/local/lib/erlang"
  @guest_elixir_root "/usr/local"
  @guest_mix_home "/usr/local/.mix"
  @guest_mix_archives "/usr/local/.mix/archives"
  @guest_elixir_make_cache "/usr/local/.cache/elixir_make"
  @guest_tmp_path "/tmp"
  @guest_tmpfs_spec "/tmp:rw,mode=1777"

  @guest_validation_runner_dir "/arbor/validation/runner"
  @guest_validation_result_dir "/arbor/validation/result"
  @guest_source_inventory_path "/arbor/validation/runner/source_inventory.json"

  @projection_specs [
    {:worktree, "/workspace", :read_write},
    {:home, "/arbor/home", :read_write},
    {:build, "/arbor/build", :read_write},
    {:deps, "/arbor/deps", :read_write},
    {:validation_runner, @guest_validation_runner_dir, :read_only},
    {:validation_result, @guest_validation_result_dir, :read_write},
    {:mix_wrapper_dir, @guest_mix_wrapper_dir, :read_only}
  ]

  @projection_keys Enum.map(@projection_specs, &elem(&1, 0))
  @projection_key_set MapSet.new(@projection_keys)
  @projection_key_strings MapSet.new(Enum.map(@projection_keys, &Atom.to_string/1))

  @allowed_mix_envs MapSet.new(["dev", "test", "prod"])

  @logical_request_keys [
    :image,
    :name,
    :projections,
    :mix_env,
    :command_args,
    :resource_profile,
    :driver,
    :platform
  ]

  @allowed_request_keys MapSet.new(
                          @logical_request_keys ++
                            Enum.map(@logical_request_keys, &Atom.to_string/1)
                        )

  @max_name_bytes 63
  @min_name_bytes 2
  @max_path_bytes 4_096
  @max_command_args SpawnCapableArgvLimits.max_command_args()
  @max_command_arg_bytes SpawnCapableArgvLimits.max_command_arg_bytes()
  @mount_field_delimiters [",", "="]
  @name_re ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @digest_image_re ~r/\Asha256:([0-9a-f]{64})\z/

  @type plan :: map()

  @doc "Closed default resource profile."
  @spec default_resource_profile() :: :standard
  def default_resource_profile, do: @default_resource_profile

  @doc "Fixed Podman executable path."
  @spec runtime_executable() :: String.t()
  def runtime_executable, do: @runtime_executable

  @doc "Fixed guest Mix wrapper path."
  @spec guest_mix_wrapper() :: String.t()
  def guest_mix_wrapper, do: @guest_mix_wrapper

  @spec new(map()) :: {:ok, plan()} | {:error, term()}
  def new(request) when is_map(request) do
    with :ok <- validate_request_keys(request),
         {:ok, image} <- fetch_image(request),
         {:ok, name} <- fetch_name(request),
         {:ok, projections} <- fetch_projections(request),
         {:ok, mix_env} <- fetch_mix_env(request),
         {:ok, command_args} <- fetch_command_args(request),
         {:ok, resource_profile} <- fetch_resource_profile(request),
         {:ok, resource_limits} <- resource_limits_for(resource_profile),
         {:ok, driver} <- fetch_driver(request),
         {:ok, platform} <- fetch_platform(request) do
      mounts = build_mounts(projections)
      env = build_env(mix_env)
      argv = build_argv(name, image, platform, mounts, env, command_args, resource_limits)

      {:ok,
       %{
         runtime_executable: @runtime_executable,
         driver: driver,
         unit_name: name,
         image: image,
         platform: platform,
         mix_env: mix_env,
         command_args: command_args,
         projections: projections,
         guest_workdir: @guest_workdir,
         guest_mix_wrapper: @guest_mix_wrapper,
         guest_tmpfs: %{guest_path: @guest_tmp_path, argv_spec: @guest_tmpfs_spec},
         resource_profile: resource_profile,
         resource_limits: resource_limits,
         mounts: mounts,
         env: env,
         argv: argv
       }}
    end
  end

  def new(_request), do: {:error, :invalid_request}

  defp validate_request_keys(request) do
    keys = Map.keys(request)

    cond do
      Enum.any?(keys, &(not MapSet.member?(@allowed_request_keys, &1))) ->
        {:error, {:unsupported_request_keys, unknown_request_keys(keys)}}

      duplicate_aliases?(keys) ->
        {:error, :duplicate_request_key_aliases}

      true ->
        :ok
    end
  end

  defp unknown_request_keys(keys) do
    keys
    |> Enum.reject(&MapSet.member?(@allowed_request_keys, &1))
    |> Enum.map(&request_key_label/1)
    |> Enum.sort()
  end

  defp request_key_label(key) when is_atom(key), do: Atom.to_string(key)
  defp request_key_label(key) when is_binary(key), do: key
  defp request_key_label(_key), do: "invalid"

  defp duplicate_aliases?(keys) do
    Enum.any?(@logical_request_keys, fn key ->
      MapSet.member?(MapSet.new(keys), key) and
        MapSet.member?(MapSet.new(keys), Atom.to_string(key))
    end)
  end

  defp fetch_image(request) do
    case get_field(request, :image) do
      nil -> {:error, :missing_image}
      image -> validate_execution_digest(image)
    end
  end

  defp fetch_name(request) do
    case get_field(request, :name) do
      nil -> {:error, :missing_name}
      name -> validate_name(name)
    end
  end

  defp fetch_projections(request) do
    case get_field(request, :projections) do
      nil -> {:error, :missing_projections}
      projections when is_map(projections) -> validate_projections(projections)
      _other -> {:error, :invalid_projections}
    end
  end

  defp fetch_mix_env(request) do
    case get_field(request, :mix_env) do
      nil -> {:error, :missing_mix_env}
      mix_env -> validate_mix_env(mix_env)
    end
  end

  defp fetch_command_args(request) do
    case get_field(request, :command_args) do
      nil -> {:ok, []}
      args when is_list(args) -> validate_command_args(args)
      _other -> {:error, :invalid_command_args}
    end
  end

  defp fetch_resource_profile(request) do
    if Map.has_key?(request, :resource_profile) or Map.has_key?(request, "resource_profile") do
      normalize_resource_profile(get_field(request, :resource_profile))
    else
      {:error, :missing_resource_profile}
    end
  end

  defp fetch_driver(request) do
    case get_field(request, :driver) do
      nil -> {:ok, :podman}
      :podman -> {:ok, :podman}
      "podman" -> {:ok, :podman}
      :docker -> {:error, :docker_driver_unimplemented}
      "docker" -> {:error, :docker_driver_unimplemented}
      _other -> {:error, :unsupported_driver}
    end
  end

  defp fetch_platform(request) do
    case get_field(request, :platform) do
      nil -> {:error, :missing_platform}
      platform -> validate_platform(platform)
    end
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp validate_execution_digest(image) when is_binary(image) do
    with :ok <- require_valid_utf8(image) do
      cond do
        image == "" ->
          {:error, :empty_image}

        String.contains?(image, "/") or String.contains?(image, "@") ->
          {:error, :external_provisioning_reference}

        String.contains?(image, ":") and not String.starts_with?(image, "sha256:") ->
          {:error, :mutable_image_tag}

        match?([^image, _digest], Regex.run(@digest_image_re, image)) ->
          {:ok, image}

        String.starts_with?(image, "sha256:") ->
          {:error, :malformed_image_digest}

        true ->
          {:error, :not_digest_execution_image}
      end
    end
  end

  defp validate_execution_digest(_image), do: {:error, :invalid_image}

  defp validate_platform(platform) when is_binary(platform) do
    if MapSet.member?(@allowed_platforms, platform) do
      {:ok, platform}
    else
      {:error, :unsupported_platform}
    end
  end

  defp validate_platform(_platform), do: {:error, :invalid_platform}

  defp validate_name(name) when is_binary(name) do
    with :ok <- require_valid_utf8(name) do
      cond do
        byte_size(name) < @min_name_bytes -> {:error, :name_too_short}
        byte_size(name) > @max_name_bytes -> {:error, :name_too_long}
        not Regex.match?(@name_re, name) -> {:error, :invalid_name}
        true -> {:ok, name}
      end
    end
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  defp validate_mix_env(mix_env) when is_binary(mix_env) do
    if MapSet.member?(@allowed_mix_envs, mix_env) do
      {:ok, mix_env}
    else
      {:error, :disallowed_mix_env}
    end
  end

  defp validate_mix_env(mix_env) when is_atom(mix_env) do
    validate_mix_env(Atom.to_string(mix_env))
  end

  defp validate_mix_env(_mix_env), do: {:error, :invalid_mix_env}

  defp normalize_resource_profile(profile) when profile in [:standard, :intensive],
    do: {:ok, profile}

  defp normalize_resource_profile("standard"), do: {:ok, :standard}
  defp normalize_resource_profile("intensive"), do: {:ok, :intensive}
  defp normalize_resource_profile(_profile), do: {:error, :invalid_resource_profile}

  defp resource_limits_for(profile) do
    case Map.fetch(@resource_profiles, profile) do
      {:ok, limits} -> {:ok, limits}
      :error -> {:error, :invalid_resource_profile}
    end
  end

  defp validate_command_args(args) do
    cond do
      length(args) > @max_command_args ->
        {:error, :too_many_command_args}

      not Enum.all?(args, &valid_command_arg?/1) ->
        {:error, :invalid_command_args}

      true ->
        {:ok, args}
    end
  end

  defp valid_command_arg?(arg) when is_binary(arg) do
    String.valid?(arg) and byte_size(arg) <= @max_command_arg_bytes and
      not String.contains?(arg, <<0>>)
  end

  defp valid_command_arg?(_arg), do: false

  defp validate_projections(projections) do
    with :ok <- validate_projection_keys(projections),
         {:ok, normalized} <- normalize_projections(projections),
         :ok <- validate_projection_paths(normalized),
         :ok <- reject_duplicate_paths(normalized),
         :ok <- reject_overlapping_paths(normalized) do
      {:ok, normalized}
    end
  end

  defp validate_projection_keys(projections) do
    keys = Map.keys(projections)

    keys_ok? =
      Enum.all?(keys, fn
        key when is_atom(key) -> MapSet.member?(@projection_key_set, key)
        key when is_binary(key) -> MapSet.member?(@projection_key_strings, key)
        _other -> false
      end)

    required_present? =
      Enum.all?(@projection_keys, fn key ->
        Map.has_key?(projections, key) or Map.has_key?(projections, Atom.to_string(key))
      end)

    cond do
      not keys_ok? -> {:error, :unsupported_projection_keys}
      not required_present? -> {:error, :missing_projections}
      map_size(projections) != length(@projection_keys) -> {:error, :duplicate_projection_keys}
      true -> :ok
    end
  end

  defp normalize_projections(projections) do
    {:ok,
     Map.new(@projection_keys, fn key ->
       value =
         case Map.fetch(projections, key) do
           {:ok, v} -> v
           :error -> Map.get(projections, Atom.to_string(key))
         end

       {key, value}
     end)}
  end

  defp validate_projection_paths(projections) do
    Enum.reduce_while(projections, :ok, fn {purpose, path}, :ok ->
      case validate_projection_host_path(path) do
        {:ok, ^path} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_projection, purpose, reason}}}
      end
    end)
  end

  defp validate_projection_host_path(path) do
    with {:ok, path} <- validate_absolute_canonical_path(path),
         :ok <- reject_mount_field_delimiters(path) do
      {:ok, path}
    end
  end

  defp reject_mount_field_delimiters(path) when is_binary(path) do
    if Enum.any?(@mount_field_delimiters, &String.contains?(path, &1)) do
      {:error, :mount_field_delimiter}
    else
      :ok
    end
  end

  defp reject_duplicate_paths(projections) do
    paths = Map.values(projections)

    if length(paths) == length(Enum.uniq(paths)) do
      :ok
    else
      {:error, :duplicate_projection_paths}
    end
  end

  defp reject_overlapping_paths(projections) do
    pairs =
      projections
      |> Enum.to_list()
      |> combination_pairs()

    Enum.reduce_while(pairs, :ok, fn {{purpose_a, path_a}, {purpose_b, path_b}}, :ok ->
      if segment_path_overlap?(path_a, path_b) do
        {:halt, {:error, {:overlapping_projection_paths, purpose_a, purpose_b}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp combination_pairs([]), do: []
  defp combination_pairs([_]), do: []

  defp combination_pairs([head | tail]) do
    Enum.map(tail, &{head, &1}) ++ combination_pairs(tail)
  end

  defp segment_path_overlap?(path_a, path_b) when path_a == path_b, do: true

  defp segment_path_overlap?(path_a, path_b) do
    segments_a = Path.split(path_a)
    segments_b = Path.split(path_b)

    List.starts_with?(segments_a, segments_b) or List.starts_with?(segments_b, segments_a)
  end

  defp validate_absolute_canonical_path(path) when is_binary(path) do
    with :ok <- require_valid_utf8(path) do
      cond do
        path == "" -> {:error, :empty_path}
        byte_size(path) > @max_path_bytes -> {:error, :path_too_long}
        String.contains?(path, <<0>>) -> {:error, :nul_byte}
        not String.starts_with?(path, "/") -> {:error, :relative_path}
        String.contains?(path, "//") -> {:error, :non_canonical_path}
        path != "/" and String.ends_with?(path, "/") -> {:error, :trailing_slash}
        Enum.any?(Path.split(path), &(&1 in [".", ".."])) -> {:error, :dot_segment}
        true -> {:ok, path}
      end
    end
  end

  defp validate_absolute_canonical_path(_path), do: {:error, :invalid_path}

  defp build_mounts(projections) do
    Enum.map(@projection_specs, fn {purpose, guest_path, mode} ->
      host_path = Map.fetch!(projections, purpose)

      %{
        purpose: purpose,
        host_path: host_path,
        guest_path: guest_path,
        mode: mode,
        mount_spec: bind_mount_spec(host_path, guest_path, mode)
      }
    end)
  end

  defp bind_mount_spec(host_path, guest_path, :read_write) do
    "type=bind,source=#{host_path},destination=#{guest_path}"
  end

  defp bind_mount_spec(host_path, guest_path, :read_only) do
    "type=bind,source=#{host_path},destination=#{guest_path},ro=true"
  end

  defp build_env(mix_env) do
    [
      {"HOME", "/arbor/home"},
      {"TMPDIR", @guest_tmp_path},
      {"MIX_BUILD_PATH", "/arbor/build"},
      {"MIX_DEPS_PATH", "/arbor/deps"},
      {"MIX_HOME", @guest_mix_home},
      {"MIX_ARCHIVES", @guest_mix_archives},
      {"ELIXIR_MAKE_CACHE_DIR", @guest_elixir_make_cache},
      {"ARBOR_MIX_CONTAINED", "1"},
      {"ARBOR_SOURCE_INVENTORY_PATH", @guest_source_inventory_path},
      {"ARBOR_ERLANG_ROOT", @guest_erlang_root},
      {"ARBOR_ELIXIR_ROOT", @guest_elixir_root},
      {"MIX_ENV", mix_env}
    ]
  end

  defp build_argv(name, image, platform, mounts, env, command_args, resource_limits) do
    create =
      [
        @runtime_executable,
        "create",
        "--name",
        name,
        "--platform",
        platform,
        "--pull",
        "never",
        "--network",
        "none",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--userns",
        "keep-id",
        "--cpus",
        resource_limits.cpus,
        "--memory",
        resource_limits.memory,
        "--pids-limit",
        resource_limits.pids
      ]
      |> Kernel.++(mount_argv(mounts))
      |> Kernel.++(["--tmpfs", @guest_tmpfs_spec])
      |> Kernel.++(["--workdir", @guest_workdir])
      |> Kernel.++(env_argv(env))
      |> Kernel.++(["--entrypoint", @guest_mix_wrapper, image])
      |> Kernel.++(command_args)

    %{
      create: create,
      start: [@runtime_executable, "start", "--attach", name],
      force_stop: [@runtime_executable, "kill", "--signal", "KILL", name],
      delete: [@runtime_executable, "rm", "--force", name],
      verify_absent: [@runtime_executable, "container", "exists", name]
    }
  end

  defp mount_argv(mounts) do
    Enum.flat_map(mounts, fn mount -> ["--mount", mount.mount_spec] end)
  end

  defp env_argv(env) do
    Enum.flat_map(env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp require_valid_utf8(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8}
  end
end
