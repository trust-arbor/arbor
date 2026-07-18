defmodule Arbor.Shell.AppleContainerExecutionCore do
  @moduledoc """
  Pure Apple Container execution-request core (Slice 2C/2D foundation).

  Converts a future Shell facade envelope plus an internally obtained
  `AppleContainerProber` admitted receipt into a validated
  `AppleContainerPlanCore` plan and bounded execution settings.

  The Actions envelope retains file-level authority for the reviewed Mix
  wrapper. After `tool_name` is proven equal to that exact file path, this
  core derives its canonical parent directory for PlanCore's read-only bind.

  Performs no IO, process execution, filesystem access, environment reads,
  Application config reads, or GenServer calls. Used by the internal
  `AppleContainerExecutor` that backs `Arbor.Shell.execute_spawn_capable/3`.
  """

  alias Arbor.Shell.AppleContainerPlanCore
  alias Arbor.Shell.SpawnCapableArgvLimits
  alias Arbor.Shell.SpawnCapableTimeout

  @runtime_path "/usr/local/bin/container"
  @guest_platform "linux/arm64"
  @required_host_arch "arm64"

  @default_max_output_bytes 8_388_608
  @hard_max_output_bytes 16_777_216
  # Profile-aware timeout ceilings are resolved via SpawnCapableTimeout.

  @max_path_bytes 4_096
  @max_command_args SpawnCapableArgvLimits.max_command_args()
  @max_command_arg_bytes SpawnCapableArgvLimits.max_command_arg_bytes()
  @max_name_bytes 63
  @min_name_bytes 2
  @max_env_entries 256

  @logical_input_keys [:tool_name, :args, :opts, :admission, :unit_name]
  @allowed_input_keys MapSet.new(
                        @logical_input_keys ++ Enum.map(@logical_input_keys, &Atom.to_string/1)
                      )

  @allowed_opt_keys MapSet.new([
                      :cwd,
                      :timeout,
                      :max_output_bytes,
                      :sandbox,
                      :env,
                      :clear_env,
                      :filesystem_projections,
                      # Optional closed capacity selector (:standard | :intensive).
                      # Raw :cpus/:memory and open resource maps are never admitted.
                      :resource_profile
                    ])

  @required_opt_keys [:cwd, :timeout, :sandbox, :env, :clear_env, :filesystem_projections]

  @forbidden_authority_keys MapSet.new([
                              :image,
                              :init_image,
                              :kernel,
                              :kernel_path,
                              :runtime,
                              :runtime_executable,
                              :plan,
                              :argv,
                              :mounts,
                              :policy,
                              :evidence,
                              :authority,
                              :module,
                              :callback,
                              :receipt,
                              "image",
                              "init_image",
                              "kernel",
                              "kernel_path",
                              "runtime",
                              "runtime_executable",
                              "plan",
                              "argv",
                              "mounts",
                              "policy",
                              "evidence",
                              "authority",
                              "module",
                              "callback",
                              "receipt"
                            ])

  # Closed Actions envelope: %{read_only: [entry...], read_write: [entry...], revision: ...}
  # Entries are closed maps with path/mode/purpose (atom or string keys). The retired
  # revision-runtime parent purpose is intentionally absent.
  @envelope_logical_keys [:read_only, :read_write, :revision]
  @allowed_envelope_keys MapSet.new(
                           @envelope_logical_keys ++
                             Enum.map(@envelope_logical_keys, &Atom.to_string/1)
                         )

  @read_only_purposes [:runtime_erlang, :runtime_elixir, :mix_wrapper, :validation_runner]
  @read_write_purposes [:worktree, :home, :tmp, :build, :deps, :validation_result]
  @projection_specs Enum.map(@read_only_purposes, &{&1, :read_only}) ++
                      Enum.map(@read_write_purposes, &{&1, :read_write})

  @projection_purposes Enum.map(@projection_specs, &elem(&1, 0))
  @projection_purpose_strings MapSet.new(Enum.map(@projection_purposes, &Atom.to_string/1))
  @required_modes Map.new(@projection_specs)
  @read_only_purpose_set MapSet.new(@read_only_purposes)
  @read_write_purpose_set MapSet.new(@read_write_purposes)

  @allowed_revisions MapSet.new(["candidate", "base"])
  @allowed_revision_atoms MapSet.new([:candidate, :base])

  # Host bind sources only for Apple PlanCore. `:tmp` remains mandatory on the
  # owner filesystem_projections envelope for broader validation lifecycle, but
  # is omitted here — guest /tmp is a fixed private tmpfs, not a host bind.
  # `:validation_runner` / `:validation_result` are revision-private sibling dirs
  # under the unprojected runtime parent (never the parent itself).
  @plan_directory_projection_keys [
    :worktree,
    :home,
    :build,
    :deps,
    :validation_runner,
    :validation_result
  ]

  @entry_logical_keys [:path, :mode, :purpose]
  @allowed_entry_keys MapSet.new(
                        @entry_logical_keys ++ Enum.map(@entry_logical_keys, &Atom.to_string/1)
                      )

  @allowed_mix_envs MapSet.new(["dev", "test", "prod"])

  @test_tag_re ~r/\A[A-Za-z_][A-Za-z0-9_.-]*\z/
  @seed_re ~r/\A[0-9]+\z/
  @test_path_re ~r/\A(?:apps\/[A-Za-z0-9_.-]+\/)?test(?:\/[A-Za-z0-9_.()&+@ -]+)*(?::\d+)?\z/
  @format_path_re ~r/\A[A-Za-z0-9_.()&+@ -]+(?:\/[A-Za-z0-9_.()&+@ -]+)*\z/
  @name_re ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @xref_formats MapSet.new(["stats", "cycles", "linked"])

  @type execution_spec :: %{
          plan: AppleContainerPlanCore.plan(),
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer()
        }

  @doc """
  Construct a validated execution spec from a closed facade envelope + admission.

  Authority for image, vminit, kernel, and runtime executable is taken only
  from the admitted receipt — never from caller-supplied override fields.
  """
  @spec new(term()) :: {:ok, execution_spec()} | {:error, term()}
  def new(input) when is_map(input) do
    with :ok <- reject_forbidden_authority_keys(input),
         :ok <- validate_input_keys(input),
         {:ok, tool_name} <- fetch_tool_name(input),
         {:ok, args} <- fetch_args(input),
         {:ok, opts} <- fetch_opts(input),
         {:ok, admission} <- fetch_admission(input),
         {:ok, unit_name} <- fetch_unit_name(input),
         {:ok, prepared} <- prepare_caller_request(tool_name, args, opts),
         {:ok, authority} <- extract_admission_authority(admission),
         plan_request <-
           build_plan_request(
             authority,
             unit_name,
             prepared.projections,
             prepared.mix_wrapper_dir,
             prepared.mix_env,
             prepared.command_args,
             prepared.resource_profile
           ),
         {:ok, plan} <- AppleContainerPlanCore.new(plan_request) do
      {:ok,
       %{
         plan: plan,
         timeout_ms: prepared.timeout,
         max_output_bytes: prepared.max_output_bytes
       }}
    end
  end

  def new(_), do: {:error, :invalid_execution_request}

  # Pure preflight for future Shell facade args (`tool_name`, `args`, `opts`).
  # Validates every caller-controlled request check that does not require an
  # admitted receipt or generated unit name. Returns `:ok` or the same bounded
  # errors as `new/1`. Validation only — not authority; no prepared plan object.
  @doc false
  @spec validate_request(term(), term(), term()) :: :ok | {:error, term()}
  def validate_request(tool_name, args, opts) do
    with {:ok, tool_name} <- normalize_tool_name(tool_name),
         {:ok, args} <- normalize_args(args),
         {:ok, opts} <- normalize_opts(opts),
         {:ok, _prepared} <- prepare_caller_request(tool_name, args, opts) do
      :ok
    end
  end

  @doc """
  JSON-clean view of an execution spec.

  Does not include arbitrary caller env values — only PlanCore's closed guest
  environment appears inside the nested plan show payload.
  """
  @spec show(execution_spec()) :: map()
  def show(%{plan: plan, timeout_ms: timeout_ms, max_output_bytes: max_output_bytes})
      when is_map(plan) and is_integer(timeout_ms) and is_integer(max_output_bytes) do
    %{
      "plan" => AppleContainerPlanCore.show(plan),
      "timeout_ms" => timeout_ms,
      "max_output_bytes" => max_output_bytes
    }
  end

  # ── Top-level input ────────────────────────────────────────────────────

  defp reject_forbidden_authority_keys(input) do
    if Enum.any?(Map.keys(input), &MapSet.member?(@forbidden_authority_keys, &1)) do
      {:error, :caller_authority_injection}
    else
      :ok
    end
  end

  defp validate_input_keys(input) do
    keys = Map.keys(input)

    with :ok <-
           reject_unknown_keys(keys, @allowed_input_keys, :unsupported_execution_request_keys),
         :ok <-
           reject_duplicate_aliases(
             keys,
             @logical_input_keys,
             :duplicate_execution_request_key_alias
           ),
         :ok <- require_all_keys(input, @logical_input_keys, :missing_execution_request_key) do
      :ok
    end
  end

  # Shared pure pipeline for facade args after tool/args/opts are normalized.
  # Returns settings needed by `new/1` only; public preflight discards this map.
  defp prepare_caller_request(tool_name, args, opts) do
    with {:ok, settings} <- validate_opts(opts),
         {:ok, projections} <- parse_filesystem_projections(settings.filesystem_projections),
         :ok <- match_tool_and_cwd(tool_name, settings.cwd, projections),
         {:ok, mix_wrapper_dir} <- derive_mix_wrapper_dir(projections),
         {:ok, command_args} <- validate_mix_argv(args, projections),
         {:ok, mix_env} <- select_mix_env(settings.env, command_args) do
      {:ok,
       %{
         command_args: command_args,
         mix_env: mix_env,
         mix_wrapper_dir: mix_wrapper_dir,
         projections: projections,
         resource_profile: settings.resource_profile,
         timeout: settings.timeout,
         max_output_bytes: settings.max_output_bytes
       }}
    end
  end

  defp fetch_tool_name(input), do: normalize_tool_name(get_field(input, :tool_name))

  defp fetch_args(input), do: normalize_args(get_field(input, :args))

  defp fetch_opts(input), do: normalize_opts(get_field(input, :opts))

  defp normalize_tool_name(path) when is_binary(path) do
    case validate_absolute_canonical_path(path) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:invalid_tool_name, reason}}
    end
  end

  defp normalize_tool_name(_other), do: {:error, :invalid_tool_name}

  defp normalize_args(args) when is_list(args), do: {:ok, args}
  defp normalize_args(_other), do: {:error, :invalid_args}

  defp normalize_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error, :invalid_opts}
    end
  end

  defp normalize_opts(_other), do: {:error, :invalid_opts}

  defp fetch_admission(input) do
    case get_field(input, :admission) do
      admission when is_map(admission) -> {:ok, admission}
      _other -> {:error, :invalid_admission}
    end
  end

  defp fetch_unit_name(input) do
    case get_field(input, :unit_name) do
      name when is_binary(name) -> validate_unit_name(name)
      _other -> {:error, :invalid_unit_name}
    end
  end

  defp validate_unit_name(name) when is_binary(name) do
    with :ok <- require_valid_utf8(name) do
      cond do
        name == "" ->
          {:error, :empty_unit_name}

        byte_size(name) < @min_name_bytes ->
          {:error, :unit_name_too_short}

        byte_size(name) > @max_name_bytes ->
          {:error, :unit_name_too_long}

        has_control_or_whitespace?(name) ->
          {:error, :unsafe_unit_name}

        not Regex.match?(@name_re, name) ->
          {:error, :unsafe_unit_name}

        true ->
          {:ok, name}
      end
    end
  end

  # ── Opts ───────────────────────────────────────────────────────────────

  defp validate_opts(opts) do
    with :ok <- reject_duplicate_opt_keys(opts),
         :ok <- reject_unknown_opt_keys(opts),
         :ok <- require_opt_keys(opts),
         {:ok, cwd} <- fetch_opt_cwd(opts),
         {:ok, resource_profile} <- fetch_opt_resource_profile(opts),
         {:ok, timeout} <- fetch_opt_timeout(opts, resource_profile),
         {:ok, max_output_bytes} <- fetch_opt_max_output_bytes(opts),
         :ok <- fetch_opt_sandbox(opts),
         {:ok, env} <- fetch_opt_env(opts),
         :ok <- fetch_opt_clear_env(opts),
         {:ok, projections} <- fetch_opt_filesystem_projections(opts) do
      {:ok,
       %{
         cwd: cwd,
         timeout: timeout,
         max_output_bytes: max_output_bytes,
         env: env,
         filesystem_projections: projections,
         resource_profile: resource_profile
       }}
    end
  end

  defp reject_duplicate_opt_keys(opts) do
    keys = Keyword.keys(opts)

    if length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :duplicate_opt_key}
    end
  end

  defp reject_unknown_opt_keys(opts) do
    unknown =
      opts
      |> Keyword.keys()
      |> Enum.reject(&MapSet.member?(@allowed_opt_keys, &1))

    cond do
      :stdin in unknown ->
        {:error, :stdin_not_supported}

      unknown != [] ->
        {:error, {:unsupported_opt_keys, Enum.map(unknown, &inspect/1) |> Enum.sort()}}

      true ->
        :ok
    end
  end

  defp require_opt_keys(opts) do
    missing =
      Enum.reject(@required_opt_keys, fn key ->
        Keyword.has_key?(opts, key)
      end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_opt_keys, missing}}
    end
  end

  defp fetch_opt_cwd(opts) do
    case Keyword.fetch!(opts, :cwd) do
      path when is_binary(path) ->
        case validate_absolute_canonical_path(path) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, {:invalid_cwd, reason}}
        end

      _other ->
        {:error, :invalid_cwd}
    end
  end

  # Timeout ceiling is keyed by the closed resource profile already selected for
  # this request. Intensive timeouts cannot be admitted under :standard.
  defp fetch_opt_timeout(opts, resource_profile) do
    case Keyword.fetch!(opts, :timeout) do
      n when is_integer(n) ->
        case SpawnCapableTimeout.validate_timeout_ms(n, resource_profile) do
          :ok -> {:ok, n}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_timeout}
    end
  end

  defp fetch_opt_max_output_bytes(opts) do
    case Keyword.fetch(opts, :max_output_bytes) do
      :error ->
        {:ok, @default_max_output_bytes}

      {:ok, n} when is_integer(n) and n > 0 and n <= @hard_max_output_bytes ->
        {:ok, n}

      {:ok, n} when is_integer(n) and n > @hard_max_output_bytes ->
        {:error, :max_output_bytes_too_large}

      {:ok, n} when is_integer(n) and n <= 0 ->
        {:error, :invalid_max_output_bytes}

      {:ok, _other} ->
        {:error, :invalid_max_output_bytes}
    end
  end

  defp fetch_opt_sandbox(opts) do
    case Keyword.fetch!(opts, :sandbox) do
      :basic -> :ok
      _other -> {:error, :invalid_sandbox}
    end
  end

  defp fetch_opt_env(opts) do
    case Keyword.fetch!(opts, :env) do
      env when is_map(env) -> {:ok, env}
      env when is_list(env) -> {:ok, env}
      _other -> {:error, :invalid_env}
    end
  end

  defp fetch_opt_clear_env(opts) do
    case Keyword.fetch!(opts, :clear_env) do
      true -> :ok
      _other -> {:error, :clear_env_required}
    end
  end

  defp fetch_opt_filesystem_projections(opts) do
    case Keyword.fetch!(opts, :filesystem_projections) do
      projections when is_map(projections) -> {:ok, projections}
      # Legacy flat lists are rejected; only the closed grouped envelope is admitted.
      _other -> {:error, :invalid_filesystem_projections}
    end
  end

  # Optional facade opt owned by Shell. Omitted → PlanCore's default profile
  # (only defaulting site). Always emits an explicit atom into PlanCore via the
  # shared `normalize_resource_profile/1` allowlist. Raw `:cpus` / `:memory`
  # remain unsupported opt keys and never reach this path.
  defp fetch_opt_resource_profile(opts) do
    case Keyword.fetch(opts, :resource_profile) do
      :error ->
        {:ok, AppleContainerPlanCore.default_resource_profile()}

      {:ok, profile} ->
        AppleContainerPlanCore.normalize_resource_profile(profile)
    end
  end

  # ── Filesystem projections ─────────────────────────────────────────────

  defp parse_filesystem_projections(projections) when is_map(projections) do
    with :ok <- validate_projection_envelope_keys(projections),
         {:ok, _revision} <- fetch_projection_revision(projections),
         {:ok, read_only_raw} <- fetch_projection_group(projections, :read_only),
         {:ok, read_write_raw} <- fetch_projection_group(projections, :read_write),
         {:ok, read_only_entries} <-
           normalize_projection_group(read_only_raw, :read_only, @read_only_purposes),
         {:ok, read_write_entries} <-
           normalize_projection_group(read_write_raw, :read_write, @read_write_purposes),
         {:ok, entries} <- merge_projection_groups(read_only_entries, read_write_entries) do
      finalize_projections(entries)
    end
  end

  defp parse_filesystem_projections(_), do: {:error, :invalid_filesystem_projections}

  defp validate_projection_envelope_keys(projections) do
    keys = Map.keys(projections)

    with :ok <-
           reject_unknown_keys(
             keys,
             @allowed_envelope_keys,
             :unsupported_filesystem_projection_keys
           ),
         :ok <-
           reject_duplicate_aliases(
             keys,
             @envelope_logical_keys,
             :duplicate_filesystem_projection_key_alias
           ),
         :ok <-
           require_all_keys(
             projections,
             @envelope_logical_keys,
             :missing_filesystem_projection_key
           ) do
      # Exact closed envelope: three logical groups only (no extras beyond aliases).
      logical_count =
        Enum.count(@envelope_logical_keys, fn key ->
          Map.has_key?(projections, key) or Map.has_key?(projections, Atom.to_string(key))
        end)

      if map_size(projections) == logical_count and
           logical_count == length(@envelope_logical_keys) do
        :ok
      else
        {:error, :invalid_filesystem_projections}
      end
    end
  end

  defp fetch_projection_revision(projections) do
    case get_field(projections, :revision) do
      revision when is_binary(revision) ->
        if MapSet.member?(@allowed_revisions, revision) do
          {:ok, revision}
        else
          {:error, :invalid_projection_revision}
        end

      revision when is_atom(revision) ->
        if MapSet.member?(@allowed_revision_atoms, revision) do
          {:ok, Atom.to_string(revision)}
        else
          {:error, :invalid_projection_revision}
        end

      nil ->
        {:error, :missing_projection_revision}

      _other ->
        {:error, :invalid_projection_revision}
    end
  end

  defp fetch_projection_group(projections, group) when group in [:read_only, :read_write] do
    case get_field(projections, group) do
      list when is_list(list) -> {:ok, list}
      _other -> {:error, {:invalid_projection_group, group}}
    end
  end

  defp normalize_projection_group(list, group_mode, required_purposes)
       when is_list(list) and is_atom(group_mode) do
    expected_count = length(required_purposes)

    if length(list) != expected_count do
      if length(list) < expected_count do
        {:error, {:missing_projections, missing_purposes_from_list(list, required_purposes)}}
      else
        {:error, :extra_projections}
      end
    else
      Enum.reduce_while(list, {:ok, %{}, MapSet.new()}, fn raw, {:ok, acc, seen} ->
        case normalize_projection_entry(raw, group_mode) do
          {:ok, entry} ->
            purpose = entry.purpose

            cond do
              not purpose_allowed_in_group?(purpose, group_mode) ->
                {:halt, {:error, {:projection_purpose_group_mismatch, purpose, group_mode}}}

              MapSet.member?(seen, purpose) ->
                {:halt, {:error, :duplicate_projection_purpose}}

              true ->
                {:cont, {:ok, Map.put(acc, purpose, entry), MapSet.put(seen, purpose)}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, entries, _seen} ->
          missing = Enum.reject(required_purposes, &Map.has_key?(entries, &1))

          cond do
            missing != [] ->
              {:error, {:missing_projections, missing}}

            map_size(entries) != expected_count ->
              {:error, :extra_projections}

            true ->
              {:ok, entries}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp missing_purposes_from_list(list, required_purposes) do
    present =
      list
      |> Enum.flat_map(fn
        entry when is_map(entry) ->
          case get_field(entry, :purpose) do
            purpose when is_atom(purpose) ->
              [purpose]

            purpose when is_binary(purpose) ->
              case parse_purpose_string(purpose) do
                {:ok, atom} -> [atom]
                _ -> []
              end

            _ ->
              []
          end

        _ ->
          []
      end)
      |> MapSet.new()

    Enum.reject(required_purposes, &MapSet.member?(present, &1))
  end

  defp purpose_allowed_in_group?(purpose, :read_only),
    do: MapSet.member?(@read_only_purpose_set, purpose)

  defp purpose_allowed_in_group?(purpose, :read_write),
    do: MapSet.member?(@read_write_purpose_set, purpose)

  defp merge_projection_groups(read_only_entries, read_write_entries) do
    overlap =
      MapSet.intersection(
        MapSet.new(Map.keys(read_only_entries)),
        MapSet.new(Map.keys(read_write_entries))
      )

    if MapSet.size(overlap) == 0 do
      {:ok, Map.merge(read_only_entries, read_write_entries)}
    else
      {:error, :duplicate_projection_purpose}
    end
  end

  defp normalize_projection_entry(entry, group_mode) when is_map(entry) and is_atom(group_mode) do
    with :ok <- validate_entry_keys(entry),
         {:ok, purpose} <- fetch_entry_purpose(entry),
         :ok <- reject_retired_runtime_purpose(purpose),
         {:ok, path} <- fetch_entry_path(entry),
         {:ok, mode} <- fetch_entry_mode(entry),
         :ok <- require_group_mode(group_mode, mode),
         :ok <- require_mode(purpose, mode) do
      {:ok, %{purpose: purpose, path: path, mode: mode}}
    end
  end

  defp normalize_projection_entry(_entry, _group_mode),
    do: {:error, :invalid_projection_entry}

  defp validate_entry_keys(entry) do
    keys = Map.keys(entry)

    with :ok <- reject_unknown_keys(keys, @allowed_entry_keys, :unsupported_projection_entry_keys),
         :ok <-
           reject_duplicate_aliases(
             keys,
             @entry_logical_keys,
             :duplicate_projection_entry_key_alias
           ),
         :ok <- require_all_keys(entry, @entry_logical_keys, :missing_projection_entry_key) do
      # Exact closed entry: path, mode, purpose only.
      logical_count =
        Enum.count(@entry_logical_keys, fn key ->
          Map.has_key?(entry, key) or Map.has_key?(entry, Atom.to_string(key))
        end)

      if map_size(entry) == logical_count and logical_count == length(@entry_logical_keys) do
        :ok
      else
        {:error, :invalid_projection_entry}
      end
    end
  end

  defp fetch_entry_purpose(entry) do
    case get_field(entry, :purpose) do
      purpose when is_atom(purpose) and purpose in @projection_purposes ->
        {:ok, purpose}

      purpose when is_atom(purpose) ->
        reject_retired_runtime_purpose(purpose)

      purpose when is_binary(purpose) ->
        parse_purpose_string(purpose)

      nil ->
        {:error, :missing_projection_purpose}

      _other ->
        {:error, :invalid_projection_purpose}
    end
  end

  defp reject_retired_runtime_purpose(:runtime),
    do: {:error, :runtime_parent_projection_forbidden}

  defp reject_retired_runtime_purpose("runtime"),
    do: {:error, :runtime_parent_projection_forbidden}

  defp reject_retired_runtime_purpose(purpose) when is_atom(purpose) do
    if purpose in @projection_purposes do
      :ok
    else
      {:error, :invalid_projection_purpose}
    end
  end

  defp reject_retired_runtime_purpose(_), do: :ok

  defp parse_purpose_string(purpose) when is_binary(purpose) do
    cond do
      purpose == "runtime" ->
        {:error, :runtime_parent_projection_forbidden}

      MapSet.member?(@projection_purpose_strings, purpose) ->
        # purpose strings are known atoms from compile-time module attributes
        {:ok, String.to_existing_atom(purpose)}

      true ->
        {:error, :invalid_projection_purpose}
    end
  end

  defp fetch_entry_path(entry) do
    case get_field(entry, :path) do
      path when is_binary(path) ->
        case validate_absolute_canonical_path(path) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, {:invalid_projection_path, reason}}
        end

      nil ->
        {:error, :missing_projection_path}

      _other ->
        {:error, :invalid_projection_path}
    end
  end

  defp fetch_entry_mode(entry) do
    case get_field(entry, :mode) do
      :read_only -> {:ok, :read_only}
      :read_write -> {:ok, :read_write}
      "read_only" -> {:ok, :read_only}
      "read_write" -> {:ok, :read_write}
      nil -> {:error, :missing_projection_mode}
      _other -> {:error, :invalid_projection_mode}
    end
  end

  defp require_group_mode(group_mode, mode) do
    if group_mode == mode do
      :ok
    else
      {:error, {:projection_group_mode_mismatch, group_mode, mode}}
    end
  end

  defp require_mode(purpose, mode) do
    case Map.fetch(@required_modes, purpose) do
      {:ok, ^mode} ->
        :ok

      {:ok, _expected} ->
        {:error, {:projection_mode_mismatch, purpose, mode}}

      :error ->
        {:error, :invalid_projection_purpose}
    end
  end

  defp finalize_projections(entries) do
    paths = Enum.map(@projection_purposes, &Map.fetch!(entries, &1).path)

    with :ok <- reject_duplicate_paths(paths),
         :ok <- reject_overlapping_paths(entries) do
      {:ok, entries}
    end
  end

  defp reject_duplicate_paths(paths) do
    if length(paths) == length(Enum.uniq(paths)) do
      :ok
    else
      {:error, :duplicate_projection_paths}
    end
  end

  defp reject_overlapping_paths(entries) do
    pairs =
      @projection_purposes
      |> Enum.map(fn purpose -> {purpose, Map.fetch!(entries, purpose).path} end)
      |> combination_pairs()

    Enum.reduce_while(pairs, :ok, fn {{pa, path_a}, {pb, path_b}}, :ok ->
      if segment_path_overlap?(path_a, path_b) do
        {:halt, {:error, {:overlapping_projection_paths, pa, pb}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp match_tool_and_cwd(tool_name, cwd, projections) do
    mix_wrapper = Map.fetch!(projections, :mix_wrapper).path
    worktree = Map.fetch!(projections, :worktree).path

    cond do
      tool_name != mix_wrapper ->
        {:error, :tool_name_mix_wrapper_mismatch}

      cwd != worktree ->
        {:error, :cwd_worktree_mismatch}

      true ->
        :ok
    end
  end

  # Apple Container 1.1.0 virtiofs bind sources must be directories. Keep the
  # Actions authority at the exact wrapper file, then derive the only directory
  # PlanCore may mount. Requiring the fixed basename preserves the fixed guest
  # entrypoint without exposing either source-parent or guest-target control.
  defp derive_mix_wrapper_dir(projections) do
    wrapper_path = Map.fetch!(projections, :mix_wrapper).path
    wrapper_dir = Path.dirname(wrapper_path)

    with :ok <- validate_mix_wrapper_mount_source(wrapper_path, wrapper_dir),
         :ok <- reject_mix_wrapper_dir_overlap(wrapper_dir, projections) do
      {:ok, wrapper_dir}
    end
  end

  defp validate_mix_wrapper_mount_source(wrapper_path, wrapper_dir) do
    case validate_absolute_canonical_path(wrapper_dir) do
      {:ok, ^wrapper_dir} ->
        if wrapper_dir != "/" and Path.join(wrapper_dir, "mix") == wrapper_path do
          :ok
        else
          {:error, :invalid_mix_wrapper_mount_source}
        end

      {:error, _reason} ->
        {:error, :invalid_mix_wrapper_mount_source}
    end
  end

  defp reject_mix_wrapper_dir_overlap(wrapper_dir, projections) do
    Enum.reduce_while(@projection_purposes, :ok, fn
      :mix_wrapper, :ok ->
        {:cont, :ok}

      purpose, :ok ->
        projection_path = Map.fetch!(projections, purpose).path

        if segment_path_overlap?(wrapper_dir, projection_path) do
          {:halt, {:error, {:overlapping_projection_paths, :mix_wrapper_dir, purpose}}}
        else
          {:cont, :ok}
        end
    end)
  end

  # ── Mix argv ───────────────────────────────────────────────────────────

  defp validate_mix_argv(args, projections) when is_list(args) and is_map(projections) do
    cond do
      length(args) > @max_command_args ->
        {:error, :too_many_command_args}

      args == [] ->
        {:error, :empty_command_args}

      not Enum.all?(args, &is_binary/1) ->
        {:error, :invalid_command_args}

      true ->
        with :ok <- validate_arg_binaries(args),
             {:ok, matched} <- match_reviewed_mix_shape(args),
             {:ok, validated} <- finalize_mix_argv(matched, projections) do
          {:ok, validated}
        end
    end
  end

  defp validate_arg_binaries(args) do
    Enum.reduce_while(args, :ok, fn arg, :ok ->
      case validate_command_arg(arg) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_command_arg(arg) when is_binary(arg) do
    with :ok <- require_valid_utf8(arg) do
      cond do
        byte_size(arg) > @max_command_arg_bytes ->
          {:error, :command_arg_too_long}

        binary_contains?(arg, <<0>>) or has_control_char?(arg) ->
          {:error, :unsafe_command_arg}

        true ->
          :ok
      end
    end
  end

  # Ordinary reviewed shapes return a concrete argv list. The security-regression
  # form returns a tagged tuple so host runner/result paths can be verified
  # against typed projections and rewritten to fixed guest paths.
  defp finalize_mix_argv(args, _projections) when is_list(args), do: {:ok, args}

  defp finalize_mix_argv({:security_regression_run, host_runner, host_result, tests}, projections)
       when is_binary(host_runner) and is_binary(host_result) and is_list(tests) do
    paths = AppleContainerPlanCore.security_regression_path_map()

    with :ok <-
           verify_security_regression_host_paths(host_runner, host_result, projections, paths) do
      {:ok,
       [
         "run",
         "--no-start",
         paths.guest_runner_script,
         "--",
         paths.guest_result_file
         | tests
       ]}
    end
  end

  defp finalize_mix_argv(_matched, _projections), do: {:error, :unsupported_mix_command}

  defp verify_security_regression_host_paths(host_runner, host_result, projections, paths) do
    runner_dir = Map.fetch!(projections, :validation_runner).path
    result_dir = Map.fetch!(projections, :validation_result).path

    expected_runner = Path.join(runner_dir, paths.runner_script_basename)
    expected_result = Path.join(result_dir, paths.result_basename)

    with {:ok, host_runner} <- validate_absolute_canonical_path(host_runner),
         {:ok, host_result} <- validate_absolute_canonical_path(host_result),
         :ok <- require_exact_path(host_runner, expected_runner, :validation_runner_path_mismatch),
         :ok <- require_exact_path(host_result, expected_result, :validation_result_path_mismatch) do
      :ok
    else
      {:error, :validation_runner_path_mismatch} = err ->
        err

      {:error, :validation_result_path_mismatch} = err ->
        err

      {:error, _reason} ->
        {:error, :invalid_security_regression_path}
    end
  end

  defp require_exact_path(actual, expected, error_tag) do
    if actual == expected do
      :ok
    else
      {:error, error_tag}
    end
  end

  defp match_reviewed_mix_shape(["compile"]), do: {:ok, ["compile"]}

  defp match_reviewed_mix_shape(["compile", "--warnings-as-errors"]),
    do: {:ok, ["compile", "--warnings-as-errors"]}

  defp match_reviewed_mix_shape(["quality"]), do: {:ok, ["quality"]}

  defp match_reviewed_mix_shape(["xref", "graph"]), do: {:ok, ["xref", "graph"]}

  defp match_reviewed_mix_shape(["xref", "graph", "--format", format])
       when is_binary(format) do
    if MapSet.member?(@xref_formats, format) do
      {:ok, ["xref", "graph", "--format", format]}
    else
      {:error, :unsupported_xref_format}
    end
  end

  # Exact security-regression harness form only:
  #   run --no-start <host-runner.exs> -- <host-result> <relative-test-paths...>
  # Reject run -e, missing sentinels, empty tests, option-shaped paths, etc.
  defp match_reviewed_mix_shape(["run", "--no-start", runner, "--", result | tests])
       when is_binary(runner) and is_binary(result) do
    with :ok <- validate_security_regression_path_token(runner, :runner),
         :ok <- validate_security_regression_path_token(result, :result),
         {:ok, tests} <- validate_test_paths(tests) do
      {:ok, {:security_regression_run, runner, result, tests}}
    end
  end

  defp match_reviewed_mix_shape(["run" | _rest]), do: {:error, :unsupported_mix_command}

  defp match_reviewed_mix_shape(["test" | rest]) do
    parse_test_args(rest, [])
  end

  defp match_reviewed_mix_shape(["format" | rest]) do
    parse_format_args(rest, [])
  end

  defp match_reviewed_mix_shape(_args), do: {:error, :unsupported_mix_command}

  defp validate_security_regression_path_token(path, role) when is_binary(path) do
    with :ok <- require_valid_utf8(path) do
      cond do
        path == "" ->
          {:error, invalid_security_regression_path_error(role)}

        Path.type(path) != :absolute and not String.starts_with?(path, "/") ->
          {:error, invalid_security_regression_path_error(role)}

        String.starts_with?(path, "-") ->
          {:error, :option_shaped_security_regression_path}

        true ->
          :ok
      end
    end
  end

  defp invalid_security_regression_path_error(:runner), do: :invalid_security_regression_runner
  defp invalid_security_regression_path_error(:result), do: :invalid_security_regression_result

  defp parse_test_args(rest, acc) do
    case rest do
      [] ->
        {:ok, ["test" | Enum.reverse(acc)]}

      ["--only", tag | more] ->
        if "--only" in acc or has_flag?(acc, "--only") do
          {:error, :duplicate_test_flag}
        else
          with :ok <- validate_test_tag(tag) do
            # ensure ordered: --only before --seed and before --
            if has_flag?(acc, "--seed") or "--" in acc do
              {:error, :reordered_test_flags}
            else
              parse_test_args(more, [tag, "--only" | acc])
            end
          end
        end

      ["--seed", seed | more] ->
        if has_flag?(acc, "--seed") do
          {:error, :duplicate_test_flag}
        else
          with :ok <- validate_seed(seed) do
            if "--" in acc do
              {:error, :reordered_test_flags}
            else
              parse_test_args(more, [seed, "--seed" | acc])
            end
          end
        end

      ["--" | paths] ->
        if "--" in acc do
          {:error, :duplicate_test_flag}
        else
          with {:ok, paths} <- validate_test_paths(paths) do
            {:ok, ["test" | Enum.reverse(acc)] ++ ["--" | paths]}
          end
        end

      _other ->
        {:error, :unsupported_mix_command}
    end
  end

  defp has_flag?(acc, flag) do
    flag in acc
  end

  defp validate_test_tag(tag) when is_binary(tag) do
    with :ok <- require_valid_utf8(tag) do
      if Regex.match?(@test_tag_re, tag) and not String.starts_with?(tag, "-") do
        :ok
      else
        {:error, :invalid_test_tag}
      end
    end
  end

  defp validate_seed(seed) when is_binary(seed) do
    with :ok <- require_valid_utf8(seed) do
      if Regex.match?(@seed_re, seed) do
        :ok
      else
        {:error, :invalid_test_seed}
      end
    end
  end

  defp validate_test_paths([]), do: {:error, :empty_test_paths}

  defp validate_test_paths(paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case validate_test_path(path) do
        :ok -> {:cont, {:ok, [path | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp validate_test_path(path) when is_binary(path) do
    with :ok <- require_valid_utf8(path) do
      components = Path.split(strip_line_suffix(path))

      cond do
        path == "" ->
          {:error, :invalid_test_path}

        Path.type(path) == :absolute or String.starts_with?(path, "/") ->
          {:error, :absolute_test_path}

        String.starts_with?(path, "-") ->
          {:error, :option_shaped_test_path}

        Enum.any?(components, &(&1 in ["", ".", ".."])) ->
          {:error, :invalid_test_path}

        not Regex.match?(@test_path_re, path) ->
          {:error, :invalid_test_path}

        true ->
          :ok
      end
    end
  end

  defp strip_line_suffix(path) do
    Regex.replace(~r/:\d+\z/, path, "")
  end

  defp parse_format_args(rest, acc) do
    case rest do
      [] ->
        {:ok, ["format" | Enum.reverse(acc)]}

      ["--check-formatted" | more] ->
        if "--check-formatted" in acc do
          {:error, :duplicate_format_flag}
        else
          if "--" in acc do
            {:error, :reordered_format_flags}
          else
            parse_format_args(more, ["--check-formatted" | acc])
          end
        end

      ["--" | paths] ->
        if "--" in acc do
          {:error, :duplicate_format_flag}
        else
          with {:ok, paths} <- validate_format_paths(paths) do
            {:ok, ["format" | Enum.reverse(acc)] ++ ["--" | paths]}
          end
        end

      _other ->
        {:error, :unsupported_mix_command}
    end
  end

  defp validate_format_paths([]), do: {:error, :empty_format_paths}

  defp validate_format_paths(paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case validate_format_path(path) do
        :ok -> {:cont, {:ok, [path | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp validate_format_path(path) when is_binary(path) do
    with :ok <- require_valid_utf8(path) do
      components = Path.split(path)

      cond do
        path == "" ->
          {:error, :invalid_format_path}

        Path.type(path) == :absolute or String.starts_with?(path, "/") ->
          {:error, :absolute_format_path}

        String.starts_with?(path, "-") ->
          {:error, :option_shaped_format_path}

        Enum.any?(components, &(&1 in ["", ".", ".."])) ->
          {:error, :invalid_format_path}

        String.contains?(path, [<<0>>, "\n", "\r", "\\"]) ->
          {:error, :invalid_format_path}

        not Regex.match?(@format_path_re, path) ->
          {:error, :invalid_format_path}

        true ->
          :ok
      end
    end
  end

  # ── Env selection ──────────────────────────────────────────────────────

  defp select_mix_env(env, command_args) do
    with {:ok, mix_env_raw} <- extract_mix_env(env) do
      case mix_env_raw do
        :default ->
          {:ok, default_mix_env(command_args)}

        value ->
          normalize_mix_env_value(value)
      end
    end
  end

  defp default_mix_env(["test" | _]), do: "test"
  defp default_mix_env(_), do: "dev"

  defp extract_mix_env(env) when is_map(env) do
    has_atom? = Map.has_key?(env, :MIX_ENV)
    has_string? = Map.has_key?(env, "MIX_ENV")

    cond do
      has_atom? and has_string? ->
        {:error, :duplicate_mix_env_alias}

      map_size(env) > @max_env_entries ->
        {:error, :env_too_large}

      has_atom? ->
        {:ok, Map.fetch!(env, :MIX_ENV)}

      has_string? ->
        {:ok, Map.fetch!(env, "MIX_ENV")}

      true ->
        # All other keys ignored.
        {:ok, :default}
    end
  end

  defp extract_mix_env(env) when is_list(env) do
    if length(env) > @max_env_entries do
      {:error, :env_too_large}
    else
      extract_mix_env_from_list(env)
    end
  end

  defp extract_mix_env(_), do: {:error, :invalid_env}

  defp extract_mix_env_from_list(env) do
    {mix_values, _others} =
      Enum.reduce(env, {[], []}, fn
        {:MIX_ENV, value}, {mix, rest} ->
          {[{:atom, value} | mix], rest}

        {"MIX_ENV", value}, {mix, rest} ->
          {[{:string, value} | mix], rest}

        {key, value}, {mix, rest} when is_atom(key) or is_binary(key) ->
          {mix, [{key, value} | rest]}

        _other, acc ->
          acc
      end)

    atom_count = Enum.count(mix_values, &match?({:atom, _}, &1))
    string_count = Enum.count(mix_values, &match?({:string, _}, &1))

    cond do
      atom_count > 1 or string_count > 1 ->
        {:error, :duplicate_mix_env}

      atom_count == 1 and string_count == 1 ->
        {:error, :duplicate_mix_env_alias}

      atom_count == 1 ->
        {:atom, value} = Enum.find(mix_values, &match?({:atom, _}, &1))
        {:ok, value}

      string_count == 1 ->
        {:string, value} = Enum.find(mix_values, &match?({:string, _}, &1))
        {:ok, value}

      true ->
        {:ok, :default}
    end
  end

  defp normalize_mix_env_value(value) when is_binary(value) do
    with :ok <- require_valid_utf8(value) do
      if MapSet.member?(@allowed_mix_envs, value) and not has_control_or_whitespace?(value) do
        {:ok, value}
      else
        {:error, :disallowed_mix_env}
      end
    end
  end

  defp normalize_mix_env_value(value) when is_atom(value) do
    normalize_mix_env_value(Atom.to_string(value))
  end

  defp normalize_mix_env_value(_), do: {:error, :invalid_mix_env}

  # ── Admission authority ────────────────────────────────────────────────

  defp extract_admission_authority(admission) when is_map(admission) do
    with :ok <- require_admitted(admission),
         {:ok, runtime_path} <- fetch_runtime_path(admission),
         :ok <- require_runtime_path(runtime_path),
         {:ok, image_ref} <- fetch_image_execution_reference(admission),
         {:ok, vminit_ref} <- fetch_vminit_execution_reference(admission),
         {:ok, kernel_path} <- fetch_kernel_path(admission),
         :ok <- validate_platforms(admission) do
      {:ok,
       %{
         image: image_ref,
         init_image: vminit_ref,
         kernel_path: kernel_path
       }}
    end
  end

  defp require_admitted(admission) do
    case get_field(admission, :admitted) do
      true -> :ok
      false -> {:error, :not_admitted}
      _other -> {:error, :invalid_admission}
    end
  end

  defp fetch_runtime_path(admission) do
    runtime = get_field(admission, :runtime)

    case runtime do
      map when is_map(map) ->
        case get_field(map, :path) do
          path when is_binary(path) -> {:ok, path}
          _other -> {:error, :missing_runtime_path}
        end

      _other ->
        {:error, :missing_runtime}
    end
  end

  defp require_runtime_path(@runtime_path), do: :ok
  defp require_runtime_path(_), do: {:error, :runtime_path_mismatch}

  defp fetch_image_execution_reference(admission) do
    image = get_field(admission, :image)

    case image do
      map when is_map(map) ->
        case get_field(map, :execution_reference) do
          ref when is_binary(ref) and ref != "" -> {:ok, ref}
          _other -> {:error, :missing_image_execution_reference}
        end

      _other ->
        {:error, :missing_image}
    end
  end

  defp fetch_vminit_execution_reference(admission) do
    vminit = get_field(admission, :vminit)

    case vminit do
      map when is_map(map) ->
        case get_field(map, :execution_reference) do
          ref when is_binary(ref) and ref != "" -> {:ok, ref}
          _other -> {:error, :missing_vminit_execution_reference}
        end

      _other ->
        {:error, :missing_vminit}
    end
  end

  defp fetch_kernel_path(admission) do
    control_plane = get_field(admission, :control_plane)

    with map when is_map(map) <- control_plane,
         kernel when is_map(kernel) <- get_field(map, :kernel),
         path when is_binary(path) <- get_field(kernel, :path) do
      case validate_absolute_canonical_path(path) do
        {:ok, path} -> {:ok, path}
        {:error, reason} -> {:error, {:invalid_kernel_path, reason}}
      end
    else
      _ -> {:error, :missing_kernel_path}
    end
  end

  defp validate_platforms(admission) do
    with :ok <- validate_host_platform(admission),
         :ok <- validate_guest_platform(get_nested(admission, [:image, :platform]), :image),
         :ok <- validate_guest_platform(get_nested(admission, [:vminit, :platform]), :vminit) do
      :ok
    end
  end

  defp validate_host_platform(admission) do
    platform = get_field(admission, :platform)

    case platform do
      map when is_map(map) ->
        arch = get_field(map, :architecture)

        if arch == @required_host_arch do
          :ok
        else
          {:error, :host_architecture_not_supported}
        end

      _other ->
        {:error, :missing_host_platform}
    end
  end

  defp validate_guest_platform(@guest_platform, _role), do: :ok

  defp validate_guest_platform(platform, role) when is_map(platform) do
    os = get_field(platform, :os)
    arch = get_field(platform, :architecture)

    if os == "linux" and arch == "arm64" do
      :ok
    else
      {:error, {:guest_platform_not_supported, role}}
    end
  end

  defp validate_guest_platform(_platform, role),
    do: {:error, {:guest_platform_not_supported, role}}

  defp get_nested(map, [key]) when is_map(map), do: get_field(map, key)

  defp get_nested(map, [key | rest]) when is_map(map) do
    case get_field(map, key) do
      nested when is_map(nested) -> get_nested(nested, rest)
      other -> other
    end
  end

  defp get_nested(_map, _keys), do: nil

  # ── Plan request assembly ──────────────────────────────────────────────

  defp build_plan_request(
         authority,
         unit_name,
         projections,
         mix_wrapper_dir,
         mix_env,
         command_args,
         resource_profile
       ) do
    plan_projections =
      @plan_directory_projection_keys
      |> Map.new(fn key ->
        {key, Map.fetch!(projections, key).path}
      end)
      |> Map.put(:mix_wrapper_dir, mix_wrapper_dir)

    host_runtime_roots = %{
      erlang: Map.fetch!(projections, :runtime_erlang).path,
      elixir: Map.fetch!(projections, :runtime_elixir).path
    }

    %{
      image: authority.image,
      init_image: authority.init_image,
      kernel_path: authority.kernel_path,
      name: unit_name,
      projections: plan_projections,
      host_runtime_roots: host_runtime_roots,
      mix_env: mix_env,
      command_args: command_args,
      resource_profile: resource_profile
    }
  end

  # ── Shared helpers ─────────────────────────────────────────────────────

  defp get_field(map, key) when is_atom(key) and is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp reject_unknown_keys(keys, allowed, error_tag) do
    if Enum.all?(keys, &MapSet.member?(allowed, &1)) do
      :ok
    else
      unknown =
        keys
        |> Enum.reject(&MapSet.member?(allowed, &1))
        |> Enum.map(&inspect/1)
        |> Enum.sort()

      {:error, {error_tag, unknown}}
    end
  end

  defp reject_duplicate_aliases(keys, logical_keys, error_tag) do
    key_set = MapSet.new(keys)

    Enum.reduce_while(logical_keys, :ok, fn atom_key, :ok ->
      has_atom? = MapSet.member?(key_set, atom_key)
      has_string? = MapSet.member?(key_set, Atom.to_string(atom_key))

      if has_atom? and has_string? do
        {:halt, {:error, {error_tag, atom_key}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp require_all_keys(map, logical_keys, error_tag) do
    missing =
      Enum.reject(logical_keys, fn key ->
        Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
      end)

    if missing == [] do
      :ok
    else
      {:error, {error_tag, missing}}
    end
  end

  defp validate_absolute_canonical_path(path) when is_binary(path) do
    with :ok <- require_valid_utf8(path) do
      cond do
        path == "" ->
          {:error, :empty_path}

        byte_size(path) > @max_path_bytes ->
          {:error, :path_too_long}

        binary_contains?(path, <<0>>) ->
          {:error, :nul_byte}

        has_control_char?(path) ->
          {:error, :control_char}

        has_whitespace?(path) ->
          {:error, :whitespace_in_path}

        not String.starts_with?(path, "/") ->
          {:error, :relative_path}

        String.contains?(path, "//") ->
          {:error, :non_canonical_path}

        path != "/" and String.ends_with?(path, "/") ->
          {:error, :trailing_slash}

        Enum.any?(Path.split(path), &(&1 in [".", ".."])) ->
          {:error, :dot_segment}

        true ->
          {:ok, path}
      end
    end
  end

  defp validate_absolute_canonical_path(_), do: {:error, :invalid_path}

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

  defp require_valid_utf8(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8}
  end

  defp has_control_char?(value) when is_binary(value) do
    Regex.match?(~r/[\x00-\x1F\x7F]/u, value)
  end

  defp has_whitespace?(value) when is_binary(value) do
    Regex.match?(~r/\s/u, value)
  end

  defp has_control_or_whitespace?(value) when is_binary(value) do
    has_control_char?(value) or has_whitespace?(value)
  end

  defp binary_contains?(binary, part)
       when is_binary(binary) and is_binary(part) do
    :binary.match(binary, part) != :nomatch
  end
end
