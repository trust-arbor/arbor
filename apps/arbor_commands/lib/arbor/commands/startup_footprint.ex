defmodule Arbor.Commands.StartupFootprint do
  @moduledoc """
  Imperative shell for the K3B startup-footprint probe.

  Compiles a tracked probe fixture once against a disposable,
  symlink-dereferenced copy of the selected dependency cache, then
  measures baseline, proposed-gated, and proposed-eager scenarios in
  separate OS/BEAM processes. Canonical `deps/` and `mix.lock` are
  read-only inputs. External commands run through Arbor.Shell's
  process-group facade. Temporary workspace output is deleted only
  after ownership and private mode are re-verified.
  """

  alias Arbor.Commands.StartupFootprint.Core
  alias Arbor.Common.SafePath

  @root_marker ["apps", "arbor_kernel", "mix.exs"]
  @template_rel ["apps", "arbor_kernel", "priv", "packaging", "startup_footprint_probe"]
  @default_policy_rel "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json"

  @owner_mix_rel [
    ["apps", "arbor_kernel", "mix.exs"],
    ["apps", "arbor_contracts", "mix.exs"],
    ["apps", "arbor_common", "mix.exs"],
    ["apps", "arbor_signals", "mix.exs"],
    ["apps", "arbor_monitor", "mix.exs"]
  ]

  @production_opt_keys [:mode, :json, :root, :policy]
  @max_workspace_create_attempts 8
  @compile_timeout_ms 300_000
  @scenario_timeout_ms 180_000
  @toolchain_timeout_ms 30_000
  @workspace_cleanup_timeout_ms 10_000
  @workspace_cleanup_max_entries 1_000_000

  @warning_needles [
    "unavailable",
    "is not available",
    "compile_env"
  ]

  @retired_config_apps ["arbor_common", "arbor_signals", "arbor_monitor", "arbor_contracts"]

  @fetch_needles [
    "Resolving Hex dependencies",
    "* Getting ",
    "* Updating "
  ]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @production_opt_keys do
      [] -> do_run(opts, allow_synthetic: false)
      unexpected -> {:error, {:production_opts_forbid_synthetic, unexpected}}
    end
  end

  def run(_), do: {:error, :invalid_opts}

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) when is_list(opts) do
    do_run(opts, allow_synthetic: true)
  end

  def run_for_test(_), do: {:error, :invalid_opts}

  @spec scenarios() :: [String.t()]
  def scenarios, do: Core.scenarios()

  @spec scenario_command(String.t()) :: [String.t()]
  def scenario_command(scenario)
      when scenario in ["baseline", "proposed_gated", "proposed_eager"] do
    ["run", "--no-start", "-e", "ArborKernelStartupFootprintProbe.run()"]
  end

  def scenario_command(_), do: []

  @doc false
  @spec allocate_workspace_at(String.t()) :: {:ok, map()} | {:error, term()}
  def allocate_workspace_at(path) when is_binary(path) do
    create_workspace_at(path)
  end

  def allocate_workspace_at(_), do: {:error, :invalid_workspace_path}

  @doc false
  @spec validate_mise_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_mise_path(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0 do
          {:ok, path}
        else
          {:error, {:mise_not_executable, path}}
        end

      {:ok, _stat} ->
        {:error, {:mise_not_executable, path}}

      {:error, :enoent} ->
        {:error, :mise_unavailable}

      {:error, reason} ->
        {:error, {:mise_unreadable, reason}}
    end
  end

  def validate_mise_path(_), do: {:error, :mise_unavailable}

  @doc false
  @spec classify_command_result(map(), term()) :: {:ok, String.t()} | {:error, term()}
  def classify_command_result(result, context) when is_map(result) do
    cond do
      Map.get(result, :timed_out) == true ->
        {:error, {:probe_timeout, context}}

      Map.get(result, :output_limit_exceeded) == true ->
        {:error, {:probe_output_limit, context}}

      Map.get(result, :containment_failure) == true ->
        {:error, {:probe_containment_failure, context}}

      Map.get(result, :exit_code) == 0 and is_binary(Map.get(result, :stdout)) ->
        {:ok, result.stdout}

      is_integer(Map.get(result, :exit_code)) ->
        {:error, {:probe_command_failed, context, result.exit_code, result.stdout}}

      true ->
        {:error, {:probe_command_failed, context, result}}
    end
  end

  def classify_command_result(_, context), do: {:error, {:probe_command_failed, context}}

  defp do_run(opts, allow_synthetic: allow_synthetic) do
    mode = Keyword.get(opts, :mode, "report")
    json? = Keyword.get(opts, :json, false) == true
    output = if json?, do: "json", else: "human"

    with :ok <- admit_mode(mode),
         {:ok, root} <- resolve_root(Keyword.get(opts, :root)),
         {:ok, policy_path} <- resolve_policy_path(root, Keyword.get(opts, :policy)),
         {:ok, policy_raw} <- load_json_map(policy_path),
         {:ok, policy} <- Core.admit_policy(policy_raw),
         {:ok, samples} <- collect_samples(root, opts, allow_synthetic),
         {:ok, evidence} <-
           Core.admit_evidence(%{
             "schema" => Core.evidence_schema(),
             "version" => 1,
             "policy_version" => Core.policy_version(),
             "samples" => samples
           }),
         {:ok, compare} <- Core.compare(policy, evidence) do
      extras = %{
        "mode" => mode,
        "output" => output,
        "comparison" => compare
      }

      {:ok, Core.show(policy, evidence, extras)}
    end
  end

  defp collect_samples(root, opts, true = _allow_synthetic) do
    cond do
      is_map(Keyword.get(opts, :samples)) ->
        admit_injected_samples(Keyword.fetch!(opts, :samples))

      Keyword.get(opts, :use_production_workspace) == true and
          is_function(Keyword.get(opts, :run_child), 2) ->
        measure_with_injected_children(root, Keyword.fetch!(opts, :run_child))

      is_function(Keyword.get(opts, :run_child), 2) ->
        run_injected_children(Keyword.fetch!(opts, :run_child))

      true ->
        {:error, :missing_synthetic_samples}
    end
  end

  defp collect_samples(root, _opts, false) do
    measure_production(root)
  end

  defp admit_injected_samples(samples) when is_map(samples) do
    Enum.reduce_while(Core.scenarios(), {:ok, %{}}, fn scenario, {:ok, acc} ->
      case Core.admit_normalized_sample(Map.get(samples, scenario)) do
        {:ok, sample} -> {:cont, {:ok, Map.put(acc, scenario, sample)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp run_injected_children(fun) do
    reduce_child_results(fn scenario ->
      fun.(scenario, %{command: scenario_command(scenario)})
    end)
  end

  defp measure_with_injected_children(root, fun) do
    with_measurement_workspace(root, fn workspace ->
      reduce_child_results(fn scenario ->
        fun.(
          scenario,
          %{
            command: scenario_command(scenario),
            deps_path: workspace.deps_copy,
            source_deps: workspace.source_deps,
            env: workspace.child_env
          }
        )
      end)
    end)
  end

  defp reduce_child_results(fun) do
    Enum.reduce_while(Core.scenarios(), {:ok, %{}}, fn scenario, {:ok, acc} ->
      case fun.(scenario) do
        {:ok, raw} when is_map(raw) ->
          case normalize_child_payload(raw) do
            {:ok, sample} -> {:cont, {:ok, Map.put(acc, scenario, sample)}}
            {:error, _} = err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}

        other ->
          {:halt, {:error, {:invalid_child_result, other}}}
      end
    end)
  end

  defp measure_production(root) do
    with_direct_runtime(fn ->
      with_measurement_workspace(root, fn workspace ->
        with {:ok, env} <-
               mix_env(root, workspace.build_path, workspace.deps_copy),
             :ok <- compile_probe(root, workspace.tmp, env),
             {:ok, samples} <- run_scenarios(root, workspace.tmp, env) do
          {:ok, samples}
        end
      end)
    end)
  end

  defp run_scenarios(root, tmp, env) do
    Enum.reduce_while(Core.scenarios(), {:ok, %{}}, fn scenario, {:ok, acc} ->
      case run_scenario(root, tmp, env, scenario) do
        {:ok, sample} -> {:cont, {:ok, Map.put(acc, scenario, sample)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp run_scenario(root, tmp, env, scenario) do
    child_env = Map.put(env, "ARBOR_STARTUP_FOOTPRINT_SCENARIO", scenario)

    case run_mix(root, tmp, child_env, scenario_command(scenario), @scenario_timeout_ms) do
      {:ok, output} ->
        with {:ok, payload} <- decode_payload(output),
             {:ok, sample} <- normalize_child_payload(payload) do
          if sample["scenario"] == scenario do
            {:ok, sample}
          else
            {:error, {:scenario_mismatch, scenario, sample["scenario"]}}
          end
        end

      {:error, {:probe_command_failed, _ctx, status, output}} ->
        {:error, {:scenario_failed, scenario, status, output}}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_child_payload(payload) do
    if Map.has_key?(payload, "process_count_delta") do
      Core.admit_normalized_sample(payload)
    else
      Core.normalize_sample(payload)
    end
  end

  defp compile_probe(root, tmp, env) do
    case run_mix(root, tmp, env, ["compile", "--warnings-as-errors"], @compile_timeout_ms) do
      {:ok, _output} -> :ok
      {:error, _} = err -> err
    end
  end

  defp run_mix(root, tmp, env, args, timeout_ms) do
    if Enum.any?(args, &(&1 in ["deps.get", "deps.update", "deps.unlock"])) do
      {:error, :refuses_network_deps}
    else
      mix = Path.join(root, "bin/mix")

      case execute_probe_command("sh", [mix | args], tmp, env, timeout_ms, {:mix, args}) do
        {:ok, output} ->
          cond do
            Enum.any?(@fetch_needles, &String.contains?(output, &1)) ->
              {:error, {:network_fetch_refused, output}}

            Enum.any?(@warning_needles, &String.contains?(output, &1)) ->
              {:error, {:probe_warning, output}}

            retired_config_warning?(output) ->
              {:error, {:probe_warning, output}}

            true ->
              {:ok, output}
          end

        {:error, {:probe_command_failed, _ctx, status, output}} ->
          {:error, {:mix_failed, args, status, output}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp execute_probe_command(command, args, cwd, env, timeout_ms, context) do
    case Arbor.Shell.execute_direct(command, args,
           sandbox: :none,
           cwd: cwd,
           env: env,
           timeout: timeout_ms,
           max_output_bytes: Arbor.Shell.max_output_bytes_limit()
         ) do
      {:ok, result} when is_map(result) ->
        classify_command_result(result, context)

      {:error, reason} ->
        {:error, {:probe_execution_failed, context, reason}}
    end
  end

  defp decode_payload(output) do
    json =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(&1, "{"))

    case json do
      nil ->
        {:error, {:payload_missing, output}}

      line ->
        case Jason.decode(line) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          {:ok, _other} -> {:error, {:payload_missing, output}}
          {:error, reason} -> {:error, {:payload_json, reason, output}}
        end
    end
  end

  defp with_measurement_workspace(root, fun) do
    with {:ok, lock_path, lock_bytes} <- read_lock(root),
         {:ok, source_deps} <- resolve_source_deps(root),
         :ok <- preflight_deps(root, source_deps),
         {:ok, workspace} <- materialize_probe(root, source_deps) do
      try do
        with {:ok, result} <- fun.(workspace),
             :ok <- assert_lock_unchanged(lock_path, lock_bytes) do
          {:ok, result}
        end
      after
        cleanup_workspace(workspace)
      end
    end
  end

  defp materialize_probe(root, source_deps) do
    with {:ok, identity} <- allocate_workspace() do
      case finish_materialize(root, source_deps, identity) do
        {:ok, workspace} ->
          {:ok, workspace}

        {:error, reason} ->
          cleanup_workspace(%{identity: identity})
          {:error, reason}
      end
    end
  end

  defp finish_materialize(root, source_deps, identity) do
    tmp = identity.path

    with :ok <- verify_owned_private(identity),
         :ok <- copy_probe_tree(root, tmp),
         {:ok, deps_copy} <- copy_deps_cache(source_deps, Path.join(tmp, "deps")),
         :ok <- verify_owned_private(identity) do
      {:ok,
       %{
         identity: identity,
         tmp: tmp,
         build_path: Path.join(tmp, "build"),
         deps_copy: deps_copy,
         source_deps: source_deps,
         child_env: %{"MIX_DEPS_PATH" => deps_copy, "HEX_OFFLINE" => "1"}
       }}
    end
  end

  defp copy_probe_tree(root, tmp) do
    template = Path.join([root | @template_rel])

    with :ok <- copy_tree(Path.join(template, "lib"), Path.join(tmp, "lib")),
         :ok <- copy_tree(Path.join(template, "config"), Path.join(tmp, "config")),
         :ok <- copy_file(Path.join(root, "mix.lock"), Path.join(tmp, "mix.lock")),
         :ok <- File.write(Path.join(tmp, "mix.exs"), generated_mix_exs(root)) do
      :ok
    else
      {:error, reason} -> {:error, {:probe_materialize_failed, reason}}
    end
  end

  defp copy_deps_cache(source_deps, dest_deps) do
    case File.cp_r(source_deps, dest_deps, dereference_symlinks: true) do
      {:ok, _files} ->
        case File.lstat(dest_deps) do
          {:ok, %{type: :directory}} -> {:ok, dest_deps}
          {:ok, %{type: :symlink}} -> {:error, :deps_copy_symlink}
          {:ok, _} -> {:error, :deps_copy_not_directory}
          {:error, reason} -> {:error, {:deps_copy_stat_failed, reason}}
        end

      {:error, reason, path} ->
        {:error, {:deps_copy_failed, reason, path}}
    end
  end

  defp copy_tree(source, dest) do
    case File.cp_r(source, dest, dereference_symlinks: true) do
      {:ok, _files} -> :ok
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end

  defp copy_file(source, dest) do
    case File.cp(source, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp generated_mix_exs(root) do
    kernel = Path.expand("apps/arbor_kernel", root)
    contracts = Path.expand("apps/arbor_contracts", root)
    common = Path.expand("apps/arbor_common", root)
    signals = Path.expand("apps/arbor_signals", root)
    monitor = Path.expand("apps/arbor_monitor", root)

    """
    # Probe-only fixture; not a production application.
    defmodule ArborKernelStartupFootprintProbe.MixProject do
      use Mix.Project

      def project do
        [
          app: :arbor_kernel_startup_footprint_probe,
          version: "0.0.0",
          elixir: "~> 1.17",
          start_permanent: Mix.env() == :prod,
          build_path: System.fetch_env!("MIX_BUILD_PATH"),
          deps_path: System.fetch_env!("MIX_DEPS_PATH"),
          deps: deps()
        ]
      end

      def application do
        [
          extra_applications: [:logger],
          mod: {ArborKernelStartupFootprintProbe.Application, []}
        ]
      end

      defp deps do
        [
          {:arbor_kernel, path: #{inspect(kernel)}, runtime: false},
          {:arbor_contracts, path: #{inspect(contracts)}, runtime: false},
          {:arbor_common, path: #{inspect(common)}, runtime: false},
          {:arbor_signals, path: #{inspect(signals)}, runtime: false},
          {:arbor_monitor, path: #{inspect(monitor)}, runtime: false},
          {:jason, "~> 1.4"}
        ]
      end
    end
    """
  end

  defp mix_env(root, build_path, deps_path) do
    with {:ok, erlang_root, elixir_root} <- pinned_roots(root) do
      {:ok,
       %{
         "ARBOR_MIX_CONTAINED" => "1",
         "ARBOR_ERLANG_ROOT" => erlang_root,
         "ARBOR_ELIXIR_ROOT" => elixir_root,
         "MIX_BUILD_PATH" => build_path,
         "MIX_DEPS_PATH" => deps_path,
         "MIX_ENV" => "prod",
         "HEX_OFFLINE" => "1"
       }}
    end
  end

  defp pinned_roots(root) do
    with {:ok, mise} <- resolve_mise(),
         {:ok, erlang} <- run_mise(mise, root, "erlang"),
         {:ok, elixir} <- run_mise(mise, root, "elixir") do
      {:ok, String.trim(erlang), String.trim(elixir)}
    else
      {:error, reason} -> {:error, {:pinned_toolchain, reason}}
    end
  end

  defp resolve_mise do
    case System.find_executable("mise") do
      path when is_binary(path) ->
        validate_mise_path(path)

      nil ->
        validate_mise_path(Path.expand("~/.local/bin/mise"))
    end
  end

  defp run_mise(mise, root, tool) do
    {command, args} = mise_invocation(mise, tool)

    execute_probe_command(
      command,
      args,
      root,
      %{},
      @toolchain_timeout_ms,
      {:mise, tool}
    )
  end

  defp mise_invocation(mise, tool) do
    case System.find_executable("mise") do
      ^mise ->
        {"mise", ["where", tool]}

      _other ->
        {"sh", [mise, "where", tool]}
    end
  end

  defp read_lock(root) do
    lock_path = Path.join(root, "mix.lock")

    case File.read(lock_path) do
      {:ok, bytes} -> {:ok, lock_path, bytes}
      {:error, :enoent} -> {:error, lock_missing_message()}
      {:error, reason} -> {:error, {:lock_unreadable, reason}}
    end
  end

  defp preflight_deps(root, deps_root) do
    names =
      Enum.flat_map(@owner_mix_rel, fn rel ->
        path = Path.join([root | rel])
        prod_hex_dep_names(path)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    missing =
      Enum.reject(names, fn name ->
        File.dir?(Path.join(deps_root, Atom.to_string(name)))
      end)

    cond do
      not File.dir?(deps_root) ->
        {:error, missing_cache_message(names)}

      missing != [] ->
        {:error, missing_cache_message(missing)}

      true ->
        :ok
    end
  end

  defp resolve_source_deps(root) do
    selected =
      case System.get_env("MIX_DEPS_PATH") do
        nil -> Path.expand("deps", root)
        path -> Path.expand(path, root)
      end

    case SafePath.resolve_real(selected) do
      {:ok, real} ->
        case File.lstat(real) do
          {:ok, %{type: :directory}} -> {:ok, real}
          {:ok, %{type: :symlink}} -> {:error, :source_deps_symlink}
          {:ok, _} -> {:error, :source_deps_not_directory}
          {:error, reason} -> {:error, {:source_deps_stat_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:source_deps_unresolved, reason}}
    end
  end

  defp allocate_workspace do
    allocate_workspace(@max_workspace_create_attempts)
  end

  defp allocate_workspace(0), do: {:error, :workspace_create_exhausted}

  defp allocate_workspace(remaining) when remaining > 0 do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    path = Path.join(System.tmp_dir!(), "arbor-startup-footprint-" <> token)

    case create_workspace_at(path) do
      {:ok, identity} -> {:ok, identity}
      {:error, :root_exists} -> allocate_workspace(remaining - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_workspace_at(path) do
    with :ok <- reject_existing_leaf(path),
         {:ok, identity} <- Arbor.Shell.create_private_owned_tree(path),
         :ok <- verify_owned_private(identity) do
      {:ok, identity}
    end
  end

  defp reject_existing_leaf(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :symlink}} ->
        {:error, :root_exists}

      {:ok, _stat} ->
        {:error, :root_exists}

      {:error, reason} ->
        {:error, {:workspace_stat_failed, reason}}
    end
  end

  defp verify_owned_private(%{
         path: path,
         device: device,
         minor_device: minor_device,
         inode: inode
       }) do
    case File.lstat(path, time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: ^device,
         minor_device: ^minor_device,
         inode: ^inode,
         uid: uid,
         mode: mode
       }} ->
        cond do
          not owner_uid?(uid) -> {:error, :workspace_owner_mismatch}
          Bitwise.band(mode, 0o777) != 0o700 -> {:error, :workspace_mode_unprivate}
          true -> :ok
        end

      {:ok, %{type: :symlink}} ->
        {:error, :workspace_symlink_rejected}

      {:ok, _stat} ->
        {:error, :workspace_identity_mismatch}

      {:error, reason} ->
        {:error, {:workspace_stat_failed, reason}}
    end
  end

  defp verify_owned_private(_), do: {:error, :invalid_workspace_identity}

  defp owner_uid?(uid) when is_integer(uid) do
    case current_uid() do
      {:ok, ^uid} -> true
      _other -> false
    end
  end

  defp owner_uid?(_), do: false

  defp current_uid do
    case Process.get({:arbor_startup_footprint, :uid}) do
      uid when is_integer(uid) ->
        {:ok, uid}

      _ ->
        case probe_current_uid() do
          {:ok, uid} = ok ->
            Process.put({:arbor_startup_footprint, :uid}, uid)
            ok

          other ->
            other
        end
    end
  end

  defp probe_current_uid do
    parent = System.tmp_dir!()
    name = ".arbor-sf-uid-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(parent, name)

    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, io} ->
        _ = :file.close(io)

        result =
          case File.lstat(path) do
            {:ok, %{uid: uid}} when is_integer(uid) -> {:ok, uid}
            _other -> :error
          end

        _ = File.rm(path)
        result

      {:error, :eexist} ->
        :error

      {:error, _reason} ->
        :error
    end
  end

  defp cleanup_workspace(%{identity: identity}) do
    with :ok <- verify_owned_private(identity) do
      Arbor.Shell.remove_owned_tree(identity,
        max_entries: @workspace_cleanup_max_entries,
        timeout_ms: @workspace_cleanup_timeout_ms
      )
    end
  end

  defp cleanup_workspace(_), do: :ok

  defp with_direct_runtime(fun) do
    case Arbor.Shell.start_direct_runtime(startup_path: direct_runtime_path()) do
      {:ok, :already_started} ->
        fun.()

      {:ok, supervisor} when is_pid(supervisor) ->
        try do
          fun.()
        after
          if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
        end

      {:error, reason} ->
        {:error, {:direct_runtime, reason}}
    end
  end

  defp direct_runtime_path do
    extras = [Path.expand("~/.local/bin")]

    [System.get_env("PATH", "") | extras]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(":")
  end

  defp prod_hex_dep_names(mix_exs) do
    case File.read(mix_exs) do
      {:ok, source} ->
        case Code.string_to_quoted(source) do
          {:ok, ast} -> collect_prod_deps(ast)
          {:error, _} -> []
        end

      {:error, _} ->
        []
    end
  end

  defp collect_prod_deps(ast) do
    ast
    |> Macro.prewalk([], fn
      {:defp, _, [{:deps, _, _}, body]} = node, acc ->
        {node, acc ++ dep_names_from_body(body)}

      other, acc ->
        {other, acc}
    end)
    |> elem(1)
  end

  defp dep_names_from_body([{:do, list}]) when is_list(list), do: dep_names_from_list(list)

  defp dep_names_from_body({:__block__, _, [list]}) when is_list(list),
    do: dep_names_from_list(list)

  defp dep_names_from_body(list) when is_list(list), do: dep_names_from_list(list)
  defp dep_names_from_body(_), do: []

  defp dep_names_from_list(list) do
    Enum.flat_map(list, fn
      {:{}, _, [name, _req, opts]} when is_atom(name) and is_list(opts) ->
        if prod_dep_opts?(opts), do: [name], else: []

      {name, opts} when is_atom(name) and is_list(opts) ->
        if prod_dep_opts?(opts), do: [name], else: []

      {:{}, _, [name, _req]} when is_atom(name) ->
        [name]

      {name, _req} when is_atom(name) ->
        [name]

      _other ->
        []
    end)
  end

  defp prod_dep_opts?(opts) do
    not Keyword.has_key?(opts, :only) and not Keyword.has_key?(opts, :in_umbrella) and
      not Keyword.has_key?(opts, :path) and Keyword.get(opts, :runtime, true) != false
  end

  defp assert_lock_unchanged(lock_path, lock_bytes) do
    case File.read(lock_path) do
      {:ok, ^lock_bytes} -> :ok
      {:ok, other} -> {:error, {:canonical_lock_mutated, byte_size(lock_bytes), byte_size(other)}}
      {:error, reason} -> {:error, {:canonical_lock_unreadable, reason}}
    end
  end

  defp resolve_root(nil), do: discover_root(File.cwd!())

  defp resolve_root(path) when is_binary(path) do
    case SafePath.validate(path) do
      :ok ->
        expanded = Path.expand(path)
        if packaging_root?(expanded), do: {:ok, expanded}, else: {:error, :invalid_root_marker}

      {:error, reason} ->
        {:error, {:root_path, reason}}
    end
  end

  defp discover_root(start) when is_binary(start), do: find_root(Path.expand(start))
  defp discover_root(_), do: {:error, :invalid_root}

  defp find_root(dir) do
    cond do
      packaging_root?(dir) -> {:ok, dir}
      Path.dirname(dir) == dir -> {:error, :umbrella_root_not_found}
      true -> find_root(Path.dirname(dir))
    end
  end

  defp packaging_root?(dir) when is_binary(dir), do: File.regular?(Path.join([dir | @root_marker]))
  defp packaging_root?(_), do: false

  defp resolve_policy_path(root, nil), do: SafePath.safe_join(root, @default_policy_rel)

  defp resolve_policy_path(root, path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      if SafePath.within?(path, root), do: {:ok, Path.expand(path)}, else: {:error, :path_escape}
    else
      SafePath.safe_join(root, path)
    end
  end

  defp load_json_map(path) do
    cond do
      not File.regular?(path) ->
        {:error, {:policy_missing, path}}

      true ->
        case File.read(path) do
          {:ok, bytes} ->
            case Jason.decode(bytes) do
              {:ok, map} when is_map(map) -> {:ok, map}
              _ -> {:error, {:policy_invalid, path}}
            end

          {:error, reason} ->
            {:error, {:policy_read, path, reason}}
        end
    end
  end

  defp admit_mode(mode) when mode in ["report", "check"], do: :ok
  defp admit_mode(_), do: {:error, :invalid_mode}

  defp retired_config_warning?(output) do
    Enum.any?(@retired_config_apps, fn app ->
      String.contains?(output, "config :" <> app)
    end)
  end

  defp missing_cache_message(names) do
    listed = Enum.map_join(names, ", ", &to_string/1)

    "canonical locked deps cache missing #{listed}; populate the umbrella once with ./bin/mix deps.get and rerun. This probe will not fetch."
  end

  defp lock_missing_message do
    "canonical locked deps cache missing mix.lock; populate the umbrella once with ./bin/mix deps.get and rerun. This probe will not fetch."
  end
end
