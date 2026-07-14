defmodule Arbor.Shell.AppleContainerPlanCore do
  @moduledoc """
  Pure Apple Container request validation and immutable argv planning.

  This core admits a closed request shape and returns create / start / cleanup
  argv plans as data only. It performs no IO, process execution, filesystem
  access, environment reads, or application config reads.

  The production `Arbor.Shell.execute_spawn_capable/3` facade remains fail-closed
  until a later imperative adapter interprets these plans.
  """

  @runtime_executable "/usr/local/bin/container"

  # Fixed resource limits for deterministic, bounded validation units.
  @cpus "1"
  @memory "2G"

  @guest_workdir "/workspace"
  @guest_mix_wrapper "/arbor/bin/mix"
  @guest_erlang_root "/usr/local/lib/erlang"
  @guest_elixir_root "/usr/local"

  # Required host projections and their fixed guest targets / modes.
  # Host Erlang/Elixir roots are provenance-only and are intentionally absent.
  @projection_specs [
    {:worktree, "/workspace", :read_write},
    {:home, "/arbor/home", :read_write},
    {:tmp, "/arbor/tmp", :read_write},
    {:build, "/arbor/build", :read_write},
    {:deps, "/arbor/deps", :read_write},
    {:runtime, "/arbor/runtime", :read_write},
    {:mix_wrapper, "/arbor/bin/mix", :read_only}
  ]

  @projection_keys Enum.map(@projection_specs, &elem(&1, 0))
  @projection_key_set MapSet.new(@projection_keys)
  @projection_key_strings MapSet.new(Enum.map(@projection_keys, &Atom.to_string/1))

  @host_runtime_root_keys [:erlang, :elixir]
  @host_runtime_root_key_set MapSet.new(@host_runtime_root_keys)
  @host_runtime_root_key_strings MapSet.new(Enum.map(@host_runtime_root_keys, &Atom.to_string/1))

  # Only MIX_ENV is caller-selectable, and only from this closed set.
  @allowed_mix_envs MapSet.new(["dev", "test", "prod"])

  # Logical top-level fields (atom form). String aliases are accepted only when
  # the atom form is absent — never both.
  @logical_request_keys [
    :image,
    :name,
    :projections,
    :host_runtime_roots,
    :mix_env,
    :command_args
  ]

  # Closed request surface — any other key fails closed.
  @allowed_request_keys MapSet.new(
                          @logical_request_keys ++
                            Enum.map(@logical_request_keys, &Atom.to_string/1)
                        )

  @max_name_bytes 63
  @min_name_bytes 2
  @max_path_bytes 4_096
  @max_image_bytes 512
  @max_command_args 256
  @max_command_arg_bytes 4_096
  @max_repository_bytes 255

  # Characters that alter Apple Container's comma-delimited --mount mini-language
  # when interpolated into source= values. Comma separates mount fields; equals
  # separates field keys from values.
  @mount_field_delimiters [",", "="]

  # Conservative DNS-like unit name for exact-ID lifecycle cleanup.
  @name_re ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  # repository@sha256:<64 lowercase hex>
  @image_re ~r/\A([a-z0-9]+(?:[._-][a-z0-9]+)*(?:\/[a-z0-9]+(?:[._-][a-z0-9]+)*)*)@sha256:([0-9a-f]{64})\z/

  @type mix_env :: String.t()
  @type host_path :: String.t()

  @type projections :: %{
          worktree: host_path(),
          home: host_path(),
          tmp: host_path(),
          build: host_path(),
          deps: host_path(),
          runtime: host_path(),
          mix_wrapper: host_path()
        }

  @type host_runtime_roots :: %{
          erlang: host_path(),
          elixir: host_path()
        }

  @type mount_plan :: %{
          purpose: atom(),
          host_path: host_path(),
          guest_path: String.t(),
          mode: :read_only | :read_write,
          mount_spec: String.t()
        }

  @type argv_plans :: %{
          create: [String.t()],
          start: [String.t()],
          force_stop: [String.t()],
          delete: [String.t()],
          verify_absent: [String.t()]
        }

  @type plan :: %{
          runtime_executable: String.t(),
          unit_name: String.t(),
          image: String.t(),
          mix_env: mix_env(),
          command_args: [String.t()],
          projections: projections(),
          host_runtime_roots: host_runtime_roots(),
          guest_runtime_roots: %{erlang: String.t(), elixir: String.t()},
          guest_workdir: String.t(),
          guest_mix_wrapper: String.t(),
          resource_limits: %{cpus: String.t(), memory: String.t()},
          mounts: [mount_plan()],
          env: [{String.t(), String.t()}],
          lifecycle: %{
            start_order: [:create | :start],
            terminal_order: [:force_stop | :delete | :verify_absent]
          },
          argv: argv_plans()
        }

  @doc """
  Construct and validate an immutable Apple Container command plan.

  Returns `{:ok, plan}` with deterministic argv for create, start/attach,
  force-stop, delete, and exact-ID absence verification. Fails closed on any
  mutable image, unsafe name, non-canonical projection, open environment, or
  attempt to control guest targets / network / extra flags.
  """
  @spec new(map()) :: {:ok, plan()} | {:error, term()}
  def new(request) when is_map(request) do
    with :ok <- validate_request_keys(request),
         {:ok, image} <- fetch_image(request),
         {:ok, name} <- fetch_name(request),
         {:ok, projections} <- fetch_projections(request),
         {:ok, host_runtime_roots} <- fetch_host_runtime_roots(request),
         {:ok, mix_env} <- fetch_mix_env(request),
         {:ok, command_args} <- fetch_command_args(request) do
      mounts = build_mounts(projections)
      env = build_env(mix_env)
      argv = build_argv(name, image, mounts, env, command_args)

      plan = %{
        runtime_executable: @runtime_executable,
        unit_name: name,
        image: image,
        mix_env: mix_env,
        command_args: command_args,
        projections: projections,
        host_runtime_roots: host_runtime_roots,
        guest_runtime_roots: %{
          erlang: @guest_erlang_root,
          elixir: @guest_elixir_root
        },
        guest_workdir: @guest_workdir,
        guest_mix_wrapper: @guest_mix_wrapper,
        resource_limits: %{cpus: @cpus, memory: @memory},
        mounts: mounts,
        env: env,
        lifecycle: %{
          start_order: [:create, :start],
          terminal_order: [:force_stop, :delete, :verify_absent]
        },
        argv: argv
      }

      {:ok, plan}
    end
  end

  def new(_), do: {:error, :invalid_request}

  @doc """
  Convert a plan to a JSON-clean map for diagnostics (no secrets beyond plan data).
  """
  @spec show(plan()) :: map()
  def show(%{argv: argv} = plan) when is_map(argv) do
    %{
      "runtime_executable" => plan.runtime_executable,
      "unit_name" => plan.unit_name,
      "image" => plan.image,
      "mix_env" => plan.mix_env,
      "command_args" => plan.command_args,
      "projections" => stringify_keys(plan.projections),
      "host_runtime_roots" => stringify_keys(plan.host_runtime_roots),
      "guest_runtime_roots" => stringify_keys(plan.guest_runtime_roots),
      "guest_workdir" => plan.guest_workdir,
      "guest_mix_wrapper" => plan.guest_mix_wrapper,
      "resource_limits" => stringify_keys(plan.resource_limits),
      "mounts" =>
        Enum.map(plan.mounts, fn mount ->
          %{
            "purpose" => Atom.to_string(mount.purpose),
            "host_path" => mount.host_path,
            "guest_path" => mount.guest_path,
            "mode" => Atom.to_string(mount.mode),
            "mount_spec" => mount.mount_spec
          }
        end),
      "env" => Enum.map(plan.env, fn {k, v} -> %{"key" => k, "value" => v} end),
      "lifecycle" => %{
        "start_order" => Enum.map(plan.lifecycle.start_order, &Atom.to_string/1),
        "terminal_order" => Enum.map(plan.lifecycle.terminal_order, &Atom.to_string/1)
      },
      "argv" => %{
        "create" => argv.create,
        "start" => argv.start,
        "force_stop" => argv.force_stop,
        "delete" => argv.delete,
        "verify_absent" => argv.verify_absent
      }
    }
  end

  @doc "Fixed runtime executable path required by every plan."
  @spec runtime_executable() :: String.t()
  def runtime_executable, do: @runtime_executable

  @doc "Fixed guest mount table (purpose → guest path + mode)."
  @spec guest_mount_table() :: [{atom(), String.t(), :read_only | :read_write}]
  def guest_mount_table, do: @projection_specs

  @doc "Fixed guest runtime roots attested by the reviewed image."
  @spec guest_runtime_roots() :: %{erlang: String.t(), elixir: String.t()}
  def guest_runtime_roots, do: %{erlang: @guest_erlang_root, elixir: @guest_elixir_root}

  @doc "Fixed resource limits applied to every create plan."
  @spec resource_limits() :: %{cpus: String.t(), memory: String.t()}
  def resource_limits, do: %{cpus: @cpus, memory: @memory}

  @doc "Allowed MIX_ENV values callers may select."
  @spec allowed_mix_envs() :: [String.t()]
  def allowed_mix_envs, do: @allowed_mix_envs |> MapSet.to_list() |> Enum.sort()

  # ── Request field extraction ───────────────────────────────────────────

  defp validate_request_keys(request) do
    keys = Map.keys(request)

    with :ok <- reject_unknown_request_keys(keys),
         :ok <- reject_duplicate_request_key_aliases(keys) do
      :ok
    end
  end

  defp reject_unknown_request_keys(keys) do
    if Enum.all?(keys, &MapSet.member?(@allowed_request_keys, &1)) do
      :ok
    else
      unknown =
        keys
        |> Enum.reject(&MapSet.member?(@allowed_request_keys, &1))
        |> Enum.map(&inspect/1)
        |> Enum.sort()

      {:error, {:unsupported_request_keys, unknown}}
    end
  end

  defp reject_duplicate_request_key_aliases(keys) do
    key_set = MapSet.new(keys)

    Enum.reduce_while(@logical_request_keys, :ok, fn atom_key, :ok ->
      has_atom? = MapSet.member?(key_set, atom_key)
      has_string? = MapSet.member?(key_set, Atom.to_string(atom_key))

      if has_atom? and has_string? do
        {:halt, {:error, {:duplicate_request_key_alias, atom_key}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp fetch_image(request) do
    case get_field(request, :image) do
      nil -> {:error, :missing_image}
      image -> validate_image(image)
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

  defp fetch_host_runtime_roots(request) do
    case get_field(request, :host_runtime_roots) do
      nil ->
        {:error, :missing_host_runtime_roots}

      roots when is_map(roots) ->
        validate_host_runtime_roots(roots)

      _other ->
        {:error, :invalid_host_runtime_roots}
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

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # ── Field validators ───────────────────────────────────────────────────

  defp validate_image(image) when is_binary(image) do
    with :ok <- require_valid_utf8(image) do
      cond do
        image == "" ->
          {:error, :empty_image}

        byte_size(image) > @max_image_bytes ->
          {:error, :image_too_long}

        has_control_or_whitespace?(image) ->
          {:error, :unsafe_image}

        option_shaped?(image) ->
          {:error, :option_shaped_image}

        String.contains?(image, ":") and not String.contains?(image, "@sha256:") ->
          {:error, :mutable_image_tag}

        String.contains?(image, "@SHA256:") or String.contains?(image, "@Sha256:") ->
          {:error, :uppercase_image_digest}

        true ->
          case Regex.run(@image_re, image) do
            [^image, repository, digest] ->
              if byte_size(repository) <= @max_repository_bytes and byte_size(digest) == 64 do
                {:ok, image}
              else
                {:error, :malformed_image}
              end

            _other ->
              if String.contains?(image, "@sha256:") do
                digest_part = image |> String.split("@sha256:", parts: 2) |> List.last()

                cond do
                  digest_part != String.downcase(digest_part) ->
                    {:error, :uppercase_image_digest}

                  not Regex.match?(~r/\A[0-9a-f]{64}\z/, digest_part) ->
                    {:error, :malformed_image_digest}

                  true ->
                    {:error, :malformed_image}
                end
              else
                {:error, :mutable_image_tag}
              end
          end
      end
    end
  end

  defp validate_image(_), do: {:error, :invalid_image}

  defp validate_name(name) when is_binary(name) do
    with :ok <- require_valid_utf8(name) do
      cond do
        name == "" ->
          {:error, :empty_name}

        byte_size(name) < @min_name_bytes ->
          {:error, :name_too_short}

        byte_size(name) > @max_name_bytes ->
          {:error, :name_too_long}

        has_control_or_whitespace?(name) ->
          {:error, :unsafe_name}

        option_shaped?(name) ->
          {:error, :option_shaped_name}

        shell_like?(name) ->
          {:error, :unsafe_name}

        not Regex.match?(@name_re, name) ->
          {:error, :unsafe_name}

        true ->
          {:ok, name}
      end
    end
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_projections(projections) when is_map(projections) do
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

    atom_or_string_ok? =
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
      not atom_or_string_ok? ->
        {:error, :unsupported_projection_keys}

      not required_present? ->
        missing =
          Enum.reject(@projection_keys, fn key ->
            Map.has_key?(projections, key) or Map.has_key?(projections, Atom.to_string(key))
          end)

        {:error, {:missing_projections, missing}}

      map_size(projections) != length(@projection_keys) ->
        {:error, :duplicate_projection_keys}

      true ->
        :ok
    end
  end

  defp normalize_projections(projections) do
    normalized =
      Map.new(@projection_keys, fn key ->
        value =
          case Map.fetch(projections, key) do
            {:ok, v} -> v
            :error -> Map.get(projections, Atom.to_string(key))
          end

        {key, value}
      end)

    {:ok, normalized}
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
    if Enum.any?(@mount_field_delimiters, &binary_contains?(path, &1)) do
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

  # Segment-aware ancestor/descendant rejection. Sibling path prefixes such as
  # /tmp/work and /tmp/worktree do not overlap.
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

  defp validate_host_runtime_roots(roots) when is_map(roots) do
    keys = Map.keys(roots)

    keys_ok? =
      Enum.all?(keys, fn
        key when is_atom(key) -> MapSet.member?(@host_runtime_root_key_set, key)
        key when is_binary(key) -> MapSet.member?(@host_runtime_root_key_strings, key)
        _other -> false
      end)

    required_present? =
      Enum.all?(@host_runtime_root_keys, fn key ->
        Map.has_key?(roots, key) or Map.has_key?(roots, Atom.to_string(key))
      end)

    cond do
      not keys_ok? ->
        {:error, :unsupported_host_runtime_root_keys}

      not required_present? ->
        {:error, :missing_host_runtime_roots}

      map_size(roots) != length(@host_runtime_root_keys) ->
        {:error, :duplicate_host_runtime_root_keys}

      true ->
        erlang =
          case Map.fetch(roots, :erlang) do
            {:ok, v} -> v
            :error -> Map.get(roots, "erlang")
          end

        elixir =
          case Map.fetch(roots, :elixir) do
            {:ok, v} -> v
            :error -> Map.get(roots, "elixir")
          end

        with {:ok, erlang_path} <- validate_absolute_canonical_path(erlang),
             {:ok, elixir_path} <- validate_absolute_canonical_path(elixir) do
          if erlang_path == elixir_path do
            {:error, :duplicate_host_runtime_roots}
          else
            {:ok, %{erlang: erlang_path, elixir: elixir_path}}
          end
        else
          {:error, reason} -> {:error, {:invalid_host_runtime_root, reason}}
        end
    end
  end

  defp validate_mix_env(mix_env) when is_binary(mix_env) do
    with :ok <- require_valid_utf8(mix_env) do
      cond do
        has_control_or_whitespace?(mix_env) ->
          {:error, :unsafe_mix_env}

        MapSet.member?(@allowed_mix_envs, mix_env) ->
          {:ok, mix_env}

        true ->
          {:error, :disallowed_mix_env}
      end
    end
  end

  defp validate_mix_env(mix_env) when is_atom(mix_env) do
    validate_mix_env(Atom.to_string(mix_env))
  end

  defp validate_mix_env(_), do: {:error, :invalid_mix_env}

  defp validate_command_args(args) when is_list(args) do
    cond do
      length(args) > @max_command_args ->
        {:error, :too_many_command_args}

      not Enum.all?(args, &is_binary/1) ->
        {:error, :invalid_command_args}

      true ->
        Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
          case validate_command_arg(arg) do
            :ok -> {:cont, {:ok, [arg | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error -> error
        end
    end
  end

  defp validate_command_arg(arg) when is_binary(arg) do
    with :ok <- require_valid_utf8(arg) do
      cond do
        byte_size(arg) > @max_command_arg_bytes ->
          {:error, :command_arg_too_long}

        has_control_char?(arg) or binary_contains?(arg, <<0>>) ->
          {:error, :unsafe_command_arg}

        true ->
          :ok
      end
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

  # ── Plan builders ──────────────────────────────────────────────────────

  defp build_mounts(projections) do
    Enum.map(@projection_specs, fn {purpose, guest_path, mode} ->
      host_path = Map.fetch!(projections, purpose)
      mount_spec = mount_spec(host_path, guest_path, mode)

      %{
        purpose: purpose,
        host_path: host_path,
        guest_path: guest_path,
        mode: mode,
        mount_spec: mount_spec
      }
    end)
  end

  defp mount_spec(host_path, guest_path, :read_write) do
    "type=bind,source=#{host_path},target=#{guest_path}"
  end

  defp mount_spec(host_path, guest_path, :read_only) do
    "type=bind,source=#{host_path},target=#{guest_path},readonly"
  end

  defp build_env(mix_env) do
    # Closed environment only. Guest paths are fixed; MIX_ENV is the sole
    # caller-selected value (already allowlisted).
    [
      {"HOME", "/arbor/home"},
      {"TMPDIR", "/arbor/tmp"},
      {"MIX_BUILD_PATH", "/arbor/build"},
      {"MIX_DEPS_PATH", "/arbor/deps"},
      {"ARBOR_MIX_CONTAINED", "1"},
      {"ARBOR_ERLANG_ROOT", @guest_erlang_root},
      {"ARBOR_ELIXIR_ROOT", @guest_elixir_root},
      {"MIX_ENV", mix_env}
    ]
  end

  defp build_argv(name, image, mounts, env, command_args) do
    # Force the reviewed wrapper via --entrypoint independently of image
    # metadata. After the image token, append only caller command_args — never
    # a second /arbor/bin/mix positional token.
    create =
      [
        @runtime_executable,
        "create",
        "--name",
        name,
        "--network",
        "none",
        "--init",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--cpus",
        @cpus,
        "--memory",
        @memory
      ]
      |> Kernel.++(mount_argv(mounts))
      |> Kernel.++(["--workdir", @guest_workdir])
      |> Kernel.++(env_argv(env))
      |> Kernel.++(["--entrypoint", @guest_mix_wrapper, image])
      |> Kernel.++(command_args)

    %{
      create: create,
      start: [@runtime_executable, "start", "--attach", name],
      force_stop: [@runtime_executable, "kill", "--signal", "KILL", name],
      delete: [@runtime_executable, "delete", name],
      verify_absent: [@runtime_executable, "inspect", name]
    }
  end

  defp mount_argv(mounts) do
    Enum.flat_map(mounts, fn mount ->
      ["--mount", mount.mount_spec]
    end)
  end

  defp env_argv(env) do
    Enum.flat_map(env, fn {key, value} ->
      ["--env", "#{key}=#{value}"]
    end)
  end

  # ── Character / shape helpers ──────────────────────────────────────────

  # Fail closed on invalid UTF-8 without raising (String.* can raise).
  defp require_valid_utf8(value) when is_binary(value) do
    if String.valid?(value) do
      :ok
    else
      {:error, :invalid_utf8}
    end
  end

  defp option_shaped?(value) when is_binary(value) do
    String.starts_with?(value, "-")
  end

  defp shell_like?(value) when is_binary(value) do
    String.contains?(value, [
      "$",
      "`",
      ";",
      "|",
      "&",
      ">",
      "<",
      "(",
      ")",
      "{",
      "}",
      "*",
      "?",
      "[",
      "]",
      "\\",
      "'",
      "\"",
      "\n",
      "\r",
      "\t",
      " "
    ])
  end

  defp has_control_or_whitespace?(value) when is_binary(value) do
    has_control_char?(value) or has_whitespace?(value) or binary_contains?(value, <<0>>)
  end

  defp has_whitespace?(value) when is_binary(value) do
    String.match?(value, ~r/[[:space:]]/)
  end

  # Byte-level ASCII control scan — does not raise on invalid UTF-8.
  defp has_control_char?(value) when is_binary(value) do
    has_control_char_bytes?(value)
  end

  defp has_control_char_bytes?(<<>>), do: false

  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true

  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)

  defp binary_contains?(haystack, needle)
       when is_binary(haystack) and is_binary(needle) and needle != "" do
    :binary.match(haystack, needle) != :nomatch
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end
end
