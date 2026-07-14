defmodule Arbor.Shell.AppleContainerExecutionCore do
  @moduledoc """
  Pure Apple Container execution-request core (Slice 2C/2D foundation).

  Converts a future Shell facade envelope plus an internally obtained
  `AppleContainerProber` admitted receipt into a validated
  `AppleContainerPlanCore` plan and bounded execution settings.

  Performs no IO, process execution, filesystem access, environment reads,
  Application config reads, or GenServer calls. Does not wire
  `Arbor.Shell.execute_spawn_capable/3` — the production facade remains
  fail-closed until a later imperative adapter exists.
  """

  alias Arbor.Shell.AppleContainerPlanCore

  @runtime_path "/usr/local/bin/container"
  @guest_platform "linux/arm64"
  @required_host_arch "arm64"

  @default_max_output_bytes 8_388_608
  @hard_max_output_bytes 16_777_216
  @min_timeout_ms 1
  @max_timeout_ms 300_000

  @max_path_bytes 4_096
  @max_command_args 256
  @max_command_arg_bytes 4_096
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
                      :filesystem_projections
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

  @projection_specs [
    {:runtime_erlang, :read_only},
    {:runtime_elixir, :read_only},
    {:mix_wrapper, :read_only},
    {:worktree, :read_write},
    {:home, :read_write},
    {:tmp, :read_write},
    {:build, :read_write},
    {:deps, :read_write},
    {:runtime, :read_write}
  ]

  @projection_purposes Enum.map(@projection_specs, &elem(&1, 0))
  @projection_purpose_set MapSet.new(@projection_purposes)
  @projection_purpose_strings MapSet.new(Enum.map(@projection_purposes, &Atom.to_string/1))
  @required_modes Map.new(@projection_specs)

  @plan_projection_keys [:worktree, :home, :tmp, :build, :deps, :runtime, :mix_wrapper]

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
         {:ok, settings} <- validate_opts(opts),
         {:ok, projections} <- parse_filesystem_projections(settings.filesystem_projections),
         :ok <- match_tool_and_cwd(tool_name, settings.cwd, projections),
         {:ok, command_args} <- validate_mix_argv(args),
         {:ok, mix_env} <- select_mix_env(settings.env, command_args),
         {:ok, authority} <- extract_admission_authority(admission),
         plan_request <-
           build_plan_request(authority, unit_name, projections, mix_env, command_args),
         {:ok, plan} <- AppleContainerPlanCore.new(plan_request) do
      {:ok,
       %{
         plan: plan,
         timeout_ms: settings.timeout,
         max_output_bytes: settings.max_output_bytes
       }}
    end
  end

  def new(_), do: {:error, :invalid_execution_request}

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

  defp fetch_tool_name(input) do
    case get_field(input, :tool_name) do
      path when is_binary(path) ->
        case validate_absolute_canonical_path(path) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, {:invalid_tool_name, reason}}
        end

      _other ->
        {:error, :invalid_tool_name}
    end
  end

  defp fetch_args(input) do
    case get_field(input, :args) do
      args when is_list(args) -> {:ok, args}
      _other -> {:error, :invalid_args}
    end
  end

  defp fetch_opts(input) do
    case get_field(input, :opts) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts) do
          {:ok, opts}
        else
          {:error, :invalid_opts}
        end

      _other ->
        {:error, :invalid_opts}
    end
  end

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
         {:ok, timeout} <- fetch_opt_timeout(opts),
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
         filesystem_projections: projections
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

  defp fetch_opt_timeout(opts) do
    case Keyword.fetch!(opts, :timeout) do
      n when is_integer(n) and n >= @min_timeout_ms and n <= @max_timeout_ms ->
        {:ok, n}

      n when is_integer(n) and n > @max_timeout_ms ->
        {:error, :timeout_too_large}

      n when is_integer(n) and n < @min_timeout_ms ->
        {:error, :timeout_too_small}

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
      projections when is_list(projections) -> {:ok, projections}
      _other -> {:error, :invalid_filesystem_projections}
    end
  end

  # ── Filesystem projections ─────────────────────────────────────────────

  defp parse_filesystem_projections(projections) when is_map(projections) do
    with :ok <- validate_projection_map_keys(projections),
         {:ok, entries} <- normalize_projection_map(projections) do
      finalize_projections(entries)
    end
  end

  defp parse_filesystem_projections(projections) when is_list(projections) do
    with {:ok, entries} <- normalize_projection_list(projections) do
      finalize_projections(entries)
    end
  end

  defp parse_filesystem_projections(_), do: {:error, :invalid_filesystem_projections}

  defp validate_projection_map_keys(projections) do
    keys = Map.keys(projections)

    keys_ok? =
      Enum.all?(keys, fn
        key when is_atom(key) -> MapSet.member?(@projection_purpose_set, key)
        key when is_binary(key) -> MapSet.member?(@projection_purpose_strings, key)
        _other -> false
      end)

    required_present? =
      Enum.all?(@projection_purposes, fn purpose ->
        Map.has_key?(projections, purpose) or Map.has_key?(projections, Atom.to_string(purpose))
      end)

    cond do
      not keys_ok? ->
        {:error, :unsupported_projection_purpose}

      not required_present? ->
        missing =
          Enum.reject(@projection_purposes, fn purpose ->
            Map.has_key?(projections, purpose) or
              Map.has_key?(projections, Atom.to_string(purpose))
          end)

        {:error, {:missing_projections, missing}}

      map_size(projections) != length(@projection_purposes) ->
        {:error, :duplicate_projection_purpose}

      true ->
        :ok
    end
  end

  defp normalize_projection_map(projections) do
    Enum.reduce_while(@projection_purposes, {:ok, %{}}, fn purpose, {:ok, acc} ->
      raw =
        case Map.fetch(projections, purpose) do
          {:ok, value} -> value
          :error -> Map.get(projections, Atom.to_string(purpose))
        end

      case normalize_projection_entry(raw, purpose) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, purpose, entry)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_projection_list(list) do
    Enum.reduce_while(list, {:ok, %{}, MapSet.new()}, fn raw, {:ok, acc, seen} ->
      with {:ok, entry} <- normalize_projection_entry(raw, :infer),
           purpose = entry.purpose,
           false <- MapSet.member?(seen, purpose) do
        {:cont, {:ok, Map.put(acc, purpose, entry), MapSet.put(seen, purpose)}}
      else
        true ->
          {:halt, {:error, :duplicate_projection_purpose}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries, _seen} ->
        missing = Enum.reject(@projection_purposes, &Map.has_key?(entries, &1))

        if missing == [] and map_size(entries) == length(@projection_purposes) do
          {:ok, entries}
        else
          if missing != [] do
            {:error, {:missing_projections, missing}}
          else
            {:error, :extra_projections}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_projection_entry(entry, expected_purpose) when is_map(entry) do
    with :ok <- validate_entry_keys(entry),
         {:ok, purpose} <- fetch_entry_purpose(entry, expected_purpose),
         {:ok, path} <- fetch_entry_path(entry),
         {:ok, mode} <- fetch_entry_mode(entry),
         :ok <- require_mode(purpose, mode) do
      {:ok, %{purpose: purpose, path: path, mode: mode}}
    end
  end

  defp normalize_projection_entry(_entry, _expected_purpose),
    do: {:error, :invalid_projection_entry}

  defp validate_entry_keys(entry) do
    keys = Map.keys(entry)

    with :ok <- reject_unknown_keys(keys, @allowed_entry_keys, :unsupported_projection_entry_keys),
         :ok <-
           reject_duplicate_aliases(
             keys,
             @entry_logical_keys,
             :duplicate_projection_entry_key_alias
           ) do
      :ok
    end
  end

  defp fetch_entry_purpose(entry, :infer) do
    case get_field(entry, :purpose) do
      purpose when is_atom(purpose) and purpose in @projection_purposes ->
        {:ok, purpose}

      purpose when is_binary(purpose) ->
        parse_purpose_string(purpose)

      nil ->
        {:error, :missing_projection_purpose}

      _other ->
        {:error, :invalid_projection_purpose}
    end
  end

  defp fetch_entry_purpose(entry, expected) when is_atom(expected) do
    expected_string = Atom.to_string(expected)

    case get_field(entry, :purpose) do
      nil ->
        {:ok, expected}

      ^expected ->
        {:ok, expected}

      purpose when is_binary(purpose) ->
        if purpose == expected_string do
          {:ok, expected}
        else
          {:error, {:projection_purpose_mismatch, expected}}
        end

      _other ->
        {:error, {:projection_purpose_mismatch, expected}}
    end
  end

  defp parse_purpose_string(purpose) when is_binary(purpose) do
    if MapSet.member?(@projection_purpose_strings, purpose) do
      # purpose strings are known atoms from compile-time module attributes
      {:ok, String.to_existing_atom(purpose)}
    else
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

  defp require_mode(purpose, mode) do
    if Map.fetch!(@required_modes, purpose) == mode do
      :ok
    else
      {:error, {:projection_mode_mismatch, purpose, mode}}
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

  # ── Mix argv ───────────────────────────────────────────────────────────

  defp validate_mix_argv(args) when is_list(args) do
    cond do
      length(args) > @max_command_args ->
        {:error, :too_many_command_args}

      args == [] ->
        {:error, :empty_command_args}

      not Enum.all?(args, &is_binary/1) ->
        {:error, :invalid_command_args}

      true ->
        with :ok <- validate_arg_binaries(args),
             {:ok, validated} <- match_reviewed_mix_shape(args) do
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

  defp match_reviewed_mix_shape(["test" | rest]) do
    parse_test_args(rest, [])
  end

  defp match_reviewed_mix_shape(["format" | rest]) do
    parse_format_args(rest, [])
  end

  defp match_reviewed_mix_shape(_args), do: {:error, :unsupported_mix_command}

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

  defp build_plan_request(authority, unit_name, projections, mix_env, command_args) do
    plan_projections =
      Map.new(@plan_projection_keys, fn key ->
        {key, Map.fetch!(projections, key).path}
      end)

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
      command_args: command_args
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
