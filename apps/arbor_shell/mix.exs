Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborShell.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_shell,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      compilers: [:arbor_shell_launcher] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      test_coverage: [threshold: 90]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Arbor.Shell.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_common, in_umbrella: true},
      {:arbor_contracts, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:bash, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Arbor.Shell",
      extras: ["README.md"]
    ]
  end
end

defmodule Mix.Tasks.Compile.ArborShellLauncher do
  @moduledoc false
  use Mix.Task.Compiler
  @recursive true

  @impl true
  def run(_args) do
    if Mix.Project.config()[:app] == :arbor_shell do
      source = Path.join(__DIR__, "c_src/arbor_shell_launcher.c")
      target = Path.join([Mix.Project.app_path(), "priv", "arbor_shell_launcher"])

      if Mix.Utils.stale?([source], [target]) do
        File.mkdir_p!(Path.dirname(target))
        compile!(source, target)
        {:ok, []}
      else
        :noop
      end
    else
      :noop
    end
  end

  @impl true
  def clean do
    if Mix.Project.config()[:app] == :arbor_shell do
      File.rm(Path.join([Mix.Project.app_path(), "priv", "arbor_shell_launcher"]))
    end

    :ok
  end

  defp compile!(source, target) do
    compiler = System.find_executable("cc") || Mix.raise("C compiler not found")

    args = [
      "-std=c11",
      "-O2",
      "-Wall",
      "-Wextra",
      "-Werror",
      "-D_POSIX_C_SOURCE=200809L",
      source,
      "-o",
      target
    ]

    case System.cmd(compiler, args, stderr_to_stdout: true) do
      {output, 0} ->
        File.chmod!(target, 0o755)
        Mix.shell().info(output)

      {output, _status} ->
        Mix.raise("failed to compile arbor_shell_launcher:\n#{output}")
    end
  end
end
