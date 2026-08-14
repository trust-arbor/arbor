defmodule Arbor.Commands.AppEnvReleaseProbe do
  @moduledoc """
  Isolated assembled-release probe for owner `:arbor_kernel` namespaces.

  Probe-only. This is not a production release definition. Canonical umbrella
  `deps/` and `mix.lock` are read-only inputs. Build and release output go to
  a fresh `MIX_BUILD_PATH`.
  """

  alias Arbor.Common.SafePath

  @root_marker ["apps", "arbor_kernel", "mix.exs"]
  @template_rel ["apps", "arbor_kernel", "priv", "packaging", "app_env_release_probe"]
  @production_opt_keys [:json, :root]
  @owner_mix_rel [
    ["apps", "arbor_kernel", "mix.exs"],
    ["apps", "arbor_contracts", "mix.exs"],
    ["apps", "arbor_common", "mix.exs"],
    ["apps", "arbor_signals", "mix.exs"],
    ["apps", "arbor_monitor", "mix.exs"]
  ]

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

  @expected %{
    "common" => %{
      "start_children" => false,
      "skill_embedding_module" => nil,
      "skill_dirs" => nil,
      "skill_embedding_dimensions" => 768,
      "tool_catalog_enabled" => true
    },
    "signals" => %{
      "start_children" => false,
      "durable_sink_module" => nil,
      "authorizer" => "Elixir.Arbor.Signals.Adapters.CapabilityAuthorizer",
      "relay_enabled" => false
    },
    "monitor" => %{
      "start_children" => false,
      "channel_bridge_module" => nil,
      "polling_interval" => 5_000,
      "signal_emission_enabled" => false
    }
  }

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @production_opt_keys do
      [] -> do_run(opts)
      unexpected -> {:error, {:production_opts_forbid_synthetic, unexpected}}
    end
  end

  def run(_), do: {:error, :invalid_opts}

  defp do_run(opts) do
    with {:ok, root} <- resolve_root(Keyword.get(opts, :root)),
         {:ok, lock_path, lock_bytes} <- read_lock(root),
         deps_path = deps_path(root),
         :ok <- preflight_deps(root, deps_path),
         {:ok, tmp} <- materialize_probe(root) do
      build_path = Path.expand(Path.join(tmp, "build"))
      File.mkdir_p!(build_path)

      try do
        with {:ok, env} <- mix_env(root, build_path, deps_path),
             :ok <- compile_release(root, tmp, env),
             {:ok, payload} <- eval_release(build_path),
             :ok <- assert_payload(payload),
             :ok <- assert_lock_unchanged(lock_path, lock_bytes) do
          {:ok, payload}
        end
      after
        File.rm_rf(tmp)
      end
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

  defp materialize_probe(root) do
    tmp =
      Path.expand(
        Path.join(
          System.tmp_dir!(),
          "arbor-app-env-release-probe-#{:erlang.unique_integer([:positive])}"
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
    # Probe-only fixture; not a production release.
    defmodule ArborKernelAppEnvProbe.MixProject do
      use Mix.Project

      def project do
        [
          app: :arbor_kernel_app_env_probe,
          version: "0.0.0",
          elixir: "~> 1.17",
          start_permanent: Mix.env() == :prod,
          build_path: System.fetch_env!("MIX_BUILD_PATH"),
          deps_path: System.fetch_env!("MIX_DEPS_PATH"),
          deps: deps(),
          releases: releases()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          {:arbor_kernel, path: #{inspect(kernel)}},
          {:arbor_contracts, path: #{inspect(contracts)}},
          {:arbor_common, path: #{inspect(common)}},
          {:arbor_signals, path: #{inspect(signals)}},
          {:arbor_monitor, path: #{inspect(monitor)}}
        ]
      end

      defp releases do
        [
          arbor_kernel_app_env_probe: [
            include_executables_for: [:unix],
            applications: [
              arbor_kernel: :permanent,
              arbor_contracts: :permanent,
              arbor_common: :permanent,
              arbor_signals: :permanent,
              arbor_monitor: :permanent,
              arbor_kernel_app_env_probe: :permanent
            ]
          ]
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

  defp compile_release(root, tmp, env) do
    mix = Path.join(root, "bin/mix")

    with :ok <- run_mix(mix, tmp, env, ["compile", "--warnings-as-errors"]),
         :ok <- run_mix(mix, tmp, env, ["release", "--overwrite"]) do
      :ok
    end
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

  defp eval_release(build_path) do
    script =
      Path.join(
        build_path,
        "rel/arbor_kernel_app_env_probe/bin/arbor_kernel_app_env_probe"
      )

    if File.regular?(script) do
      {output, status} =
        System.cmd(script, ["eval", "ArborKernelAppEnvProbe.run()"], stderr_to_stdout: true)

      cond do
        status != 0 ->
          {:error, {:release_eval_failed, status, output}}

        Enum.any?(@warning_needles, &String.contains?(output, &1)) ->
          {:error, {:probe_warning, output}}

        retired_config_warning?(output) ->
          {:error, {:probe_warning, output}}

        true ->
          decode_payload(output)
      end
    else
      {:error, {:release_script_missing, script}}
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
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:payload_json, reason, output}}
      nil -> {:error, {:payload_missing, output}}
      false -> {:error, {:payload_missing, output}}
    end
  end

  defp assert_payload(payload) do
    cond do
      not match_expected?(payload) ->
        {:error, {:payload_mismatch, payload, @expected}}

      not started_kernel?(payload) ->
        {:error, {:arbor_kernel_not_started, payload["started"]}}

      true ->
        :ok
    end
  end

  defp match_expected?(payload) do
    Enum.all?(@expected, fn {ns, expected} ->
      actual = payload[ns] || %{}
      Enum.all?(expected, fn {key, value} -> actual[key] == value end)
    end)
  end

  defp started_kernel?(payload) do
    started = payload["started"] || []
    is_list(started) and "arbor_kernel" in started
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
        if kernel_root?(expanded), do: {:ok, expanded}, else: {:error, :invalid_root_marker}

      {:error, reason} ->
        {:error, {:root_path, reason}}
    end
  end

  defp discover_root(start) when is_binary(start), do: find_root(Path.expand(start))
  defp discover_root(_), do: {:error, :invalid_root}

  defp find_root(dir) do
    cond do
      kernel_root?(dir) -> {:ok, dir}
      Path.dirname(dir) == dir -> {:error, :umbrella_root_not_found}
      true -> find_root(Path.dirname(dir))
    end
  end

  defp kernel_root?(dir) when is_binary(dir), do: File.regular?(Path.join([dir | @root_marker]))
  defp kernel_root?(_), do: false

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
