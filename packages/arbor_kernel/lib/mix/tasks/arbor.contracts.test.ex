defmodule Mix.Tasks.Arbor.Contracts.Test do
  use Boundary, classify_to: Arbor.Kernel.DevTools
  use Mix.Task

  @shortdoc "Run the exact owned contract-test inventory across Kernel and umbrella apps"
  @moduledoc """
  Runs the closed contract-change test invocation from the Arbor umbrella root.

  The only accepted options are `--no-deps-check --warnings-as-errors --`,
  followed by existing contract-test files. Kernel's package tests run in the
  canonical Kernel project with the umbrella's private build/dependency paths;
  selected app tests then use Mix's ordinary umbrella dispatch. No child OS
  process or alternate caller-supplied working directory is introduced.
  """

  @preferred_cli_env :test
  @requirements ["loadpaths"]
  @flags ["--no-deps-check", "--warnings-as-errors"]
  @prefix @flags ++ ["--"]
  @max_paths 256
  @max_path_bytes 1_024
  @max_inventory_bytes 65_536
  @app_id ~r/\A[a-z][a-z0-9_]*\z/
  @kernel_segments ["packages", "arbor_kernel"]

  @impl Mix.Task
  def run(argv) do
    unless Mix.Project.umbrella?() and Mix.env() == :test do
      Mix.raise("arbor.contracts.test requires the test environment at the Arbor umbrella root")
    end

    root = Mix.Project.project_file() |> Path.dirname() |> Path.expand()

    unless Path.expand(File.cwd!()) == root do
      Mix.raise("arbor.contracts.test requires the current umbrella root")
    end

    apps = Mix.Project.apps_paths()

    with {:ok, plan} <- plan(argv, root, apps),
         {:ok, dependency_path} <- Map.fetch(Mix.Project.deps_paths(), :arbor_kernel),
         true <- Path.expand(dependency_path) == plan.kernel_root do
      # deps_config supplies an already environment-qualified deps_build_path.
      # Passing it as build_path instead would append a second /test directory.
      inherited = Mix.Project.deps_config()

      run_kernel_phase!(plan, inherited)

      if plan.app_paths != [] do
        run_phase!("umbrella", plan.app_count, fn ->
          Mix.Task.reenable("test")
          Mix.Task.run("test", @prefix ++ plan.app_paths)
        end)
      end

      :ok
    else
      {:error, reason} ->
        Mix.raise("arbor.contracts.test rejected its inventory: #{inspect(reason)}")

      false ->
        Mix.raise("arbor.contracts.test requires the canonical Kernel package dependency")
    end
  end

  @doc false
  @spec plan([String.t()], String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def plan(argv, root, app_paths)
      when is_list(argv) and is_binary(root) and is_map(app_paths) do
    with true <- List.starts_with?(argv, @prefix),
         paths = Enum.drop(argv, length(@prefix)),
         true <- paths != [] and length(paths) <= @max_paths,
         true <- Enum.all?(paths, &is_binary/1),
         true <- Enum.reduce(paths, 0, &(byte_size(&1) + 1 + &2)) <= @max_inventory_bytes,
         true <- Path.type(root) == :absolute and Path.expand(root) == root,
         true <- regular_path?(root, ["mix.exs"], :regular),
         true <- regular_path?(root, @kernel_segments ++ ["mix.exs"], :regular),
         {:ok, classified} <- classify_paths(paths, root, app_paths) do
      kernel_paths =
        for {:kernel, path, _app} <- classified,
            do: String.replace_prefix(path, "packages/arbor_kernel/", "")

      apps = for {:app, path, _app} <- classified, do: path
      app_count = classified |> Enum.filter(&(elem(&1, 0) == :app)) |> Enum.map(&elem(&1, 2))

      {:ok,
       %{
         root: root,
         kernel_root: Path.join(root, "packages/arbor_kernel"),
         kernel_paths: kernel_paths,
         app_paths: apps,
         app_count: app_count |> Enum.uniq() |> length()
       }}
    else
      _ -> {:error, :invalid_contract_test_inventory}
    end
  end

  def plan(_argv, _root, _app_paths), do: {:error, :invalid_contract_test_inventory}

  defp classify_paths(paths, root, app_paths) do
    allowed_apps =
      Map.new(app_paths, fn {app, path} -> {Atom.to_string(app), Path.expand(path, root)} end)

    paths
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      with {:ok, segments} <- segments(path),
           true <- regular_path?(root, segments, :regular),
           {:ok, kind, app} <- classify(segments, root, allowed_apps) do
        {:cont, {:ok, [{kind, path, app} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_contract_test_inventory}}
      end
    end)
    |> case do
      {:ok, classified} -> {:ok, Enum.reverse(classified)}
      error -> error
    end
  end

  defp classify(["packages", "arbor_kernel", "test", "arbor", "contracts" | rest], _root, _apps)
       when rest != [],
       do: {:ok, :kernel, :arbor_kernel}

  defp classify(["apps", app, "test" | rest], root, apps) when rest != [] do
    expected = Path.join([root, "apps", app])

    if Regex.match?(@app_id, app) and app != "arbor_contracts" and
         Map.get(apps, app) == expected and "contracts" in Enum.drop(rest, -1) and
         regular_path?(root, ["apps", app, "mix.exs"], :regular) do
      {:ok, :app, app}
    else
      {:error, :invalid_contract_test_inventory}
    end
  end

  defp classify(_segments, _root, _apps), do: {:error, :invalid_contract_test_inventory}

  defp segments(path) do
    parts = String.split(path, "/")

    if String.valid?(path) and byte_size(path) <= @max_path_bytes and
         String.trim(path) == path and not String.contains?(path, ["\0", "\\"]) and
         Path.type(path) == :relative and
         Enum.all?(parts, &(&1 not in ["", ".", ".."] and not String.starts_with?(&1, "-"))) and
         String.ends_with?(List.last(parts), "_test.exs") do
      {:ok, parts}
    else
      {:error, :invalid_contract_test_inventory}
    end
  end

  defp regular_path?(root, segments, final_type) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> walk_path(root, segments, final_type)
      _ -> false
    end
  end

  defp walk_path(root, [leaf], final_type) do
    match?({:ok, %{type: ^final_type}}, File.lstat(Path.join(root, leaf)))
  end

  defp walk_path(root, [part | rest], final_type) do
    path = Path.join(root, part)

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> walk_path(path, rest, final_type)
      _ -> false
    end
  end

  defp run_kernel_phase!(%{kernel_paths: []}, _inherited), do: :ok

  defp run_kernel_phase!(plan, inherited) do
    run_phase!("Kernel", 1, fn ->
      Mix.Project.in_project(:arbor_kernel, plan.kernel_root, inherited, fn _ ->
        unless Mix.Project.config()[:app] == :arbor_kernel do
          Mix.raise("arbor.contracts.test loaded an unexpected Kernel project")
        end

        Mix.Task.reenable("test")
        Mix.Task.run("test", @prefix ++ plan.kernel_paths)
      end)
    end)
  end

  defp run_phase!(label, expected_suites, run) do
    {:ok, _} = Application.ensure_all_started(:ex_unit)
    owner = self()
    ref = make_ref()
    callback = fn stats -> send(owner, {__MODULE__, ref, stats}) end
    ExUnit.after_suite(callback)

    try do
      run.()
      stats = collect_stats(ref, [])

      unless length(stats) == expected_suites and Enum.all?(stats, &executed_successfully?/1) do
        Mix.raise("arbor.contracts.test #{label} tests failed or did not execute their inventory")
      end

      count = Enum.reduce(stats, 0, &(&1.total - &1.excluded - &1.skipped + &2))
      Mix.shell().info("arbor.contracts.test #{label}: #{count} executed, 0 failures")
    after
      callbacks = ExUnit.configuration()[:after_suite] || []
      ExUnit.configure(after_suite: Enum.reject(callbacks, &(&1 === callback)))
      collect_stats(ref, [])
    end
  end

  defp collect_stats(ref, acc) do
    receive do
      {__MODULE__, ^ref, stats} -> collect_stats(ref, [stats | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp executed_successfully?(%{total: total, excluded: excluded, skipped: skipped, failures: 0})
       when is_integer(total) and is_integer(excluded) and is_integer(skipped) and
              total > 0 and excluded >= 0 and skipped >= 0,
       do: total > excluded + skipped

  defp executed_successfully?(_stats), do: false
end
