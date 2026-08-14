defmodule Arbor.Commands.StartupFootprint do
  @moduledoc """
  Imperative shell for the K3B startup-footprint probe.

  Compiles a tracked probe fixture once, then measures baseline,
  proposed-gated, and proposed-eager scenarios in separate OS/BEAM
  processes. Canonical `deps/` and `mix.lock` are read-only inputs.
  Temporary build output is deleted after the run.
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

  defp collect_samples(_root, opts, true = _allow_synthetic) do
    cond do
      is_map(Keyword.get(opts, :samples)) ->
        admit_injected_samples(Keyword.fetch!(opts, :samples))

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
    Enum.reduce_while(Core.scenarios(), {:ok, %{}}, fn scenario, {:ok, acc} ->
      case fun.(scenario, %{command: scenario_command(scenario)}) do
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
    with {:ok, lock_path, lock_bytes} <- read_lock(root),
         deps_path = deps_path(root),
         :ok <- preflight_deps(root, deps_path),
         {:ok, tmp} <- materialize_probe(root) do
      build_path = Path.expand(Path.join(tmp, "build"))
      File.mkdir_p!(build_path)

      try do
        with {:ok, env} <- mix_env(root, build_path, deps_path),
             :ok <- compile_probe(root, tmp, env),
             {:ok, samples} <- run_scenarios(root, tmp, env),
             :ok <- assert_lock_unchanged(lock_path, lock_bytes) do
          {:ok, samples}
        end
      after
        File.rm_rf(tmp)
      end
    end
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
    mix = Path.join(root, "bin/mix")
    child_env = [{"ARBOR_STARTUP_FOOTPRINT_SCENARIO", scenario} | env]

    {output, status} =
      System.cmd(mix, scenario_command(scenario),
        cd: tmp,
        env: child_env,
        stderr_to_stdout: true
      )

    cond do
      status != 0 ->
        {:error, {:scenario_failed, scenario, status, output}}

      Enum.any?(@fetch_needles, &String.contains?(output, &1)) ->
        {:error, {:network_fetch_refused, output}}

      true ->
        with {:ok, payload} <- decode_payload(output),
             {:ok, sample} <- normalize_child_payload(payload) do
          if sample["scenario"] == scenario do
            {:ok, sample}
          else
            {:error, {:scenario_mismatch, scenario, sample["scenario"]}}
          end
        end
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
    run_mix(Path.join(root, "bin/mix"), tmp, env, ["compile", "--warnings-as-errors"])
  end

  defp run_mix(mix, tmp, env, args) do
    if Enum.any?(args, &(&1 in ["deps.get", "deps.update", "deps.unlock"])) do
      {:error, :refuses_network_deps}
    else
      {output, status} =
        System.cmd(mix, args, cd: tmp, env: env, stderr_to_stdout: true)

      cond do
        status != 0 ->
          {:error, {:mix_failed, args, status, output}}

        Enum.any?(@fetch_needles, &String.contains?(output, &1)) ->
          {:error, {:network_fetch_refused, output}}

        Enum.any?(@warning_needles, &String.contains?(output, &1)) ->
          {:error, {:probe_warning, output}}

        retired_config_warning?(output) ->
          {:error, {:probe_warning, output}}

        true ->
          :ok
      end
    end
  end

  defp decode_payload(output) do
    json =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(&1, "{"))

    case json && Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:error, reason} -> {:error, {:payload_json, reason, output}}
      nil -> {:error, {:payload_missing, output}}
      false -> {:error, {:payload_missing, output}}
      {:ok, _} -> {:error, {:payload_missing, output}}
    end
  end

  defp materialize_probe(root) do
    tmp =
      Path.expand(
        Path.join(
          System.tmp_dir!(),
          "arbor-startup-footprint-probe-#{:erlang.unique_integer([:positive])}"
        )
      )

    template = Path.join([root | @template_rel])
    File.mkdir_p!(tmp)
    File.cp_r!(Path.join(template, "lib"), Path.join(tmp, "lib"))
    File.cp_r!(Path.join(template, "config"), Path.join(tmp, "config"))
    File.cp!(Path.join(root, "mix.lock"), Path.join(tmp, "mix.lock"))
    File.write!(Path.join(tmp, "mix.exs"), generated_mix_exs(root))
    {:ok, tmp}
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
       [
         {"ARBOR_MIX_CONTAINED", "1"},
         {"ARBOR_ERLANG_ROOT", erlang_root},
         {"ARBOR_ELIXIR_ROOT", elixir_root},
         {"MIX_BUILD_PATH", build_path},
         {"MIX_DEPS_PATH", deps_path},
         {"MIX_ENV", "prod"}
       ]}
    end
  end

  defp pinned_roots(root) do
    mise = System.find_executable("mise") || Path.expand("~/.local/bin/mise")

    with {erlang, 0} <- System.cmd(mise, ["where", "erlang"], cd: root, stderr_to_stdout: true),
         {elixir, 0} <- System.cmd(mise, ["where", "elixir"], cd: root, stderr_to_stdout: true) do
      {:ok, String.trim(erlang), String.trim(elixir)}
    else
      {output, status} -> {:error, {:pinned_toolchain, status, output}}
      other -> {:error, {:pinned_toolchain, other}}
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

  defp deps_path(root) do
    case System.get_env("MIX_DEPS_PATH") do
      nil -> Path.expand("deps", root)
      path -> Path.expand(path, root)
    end
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
