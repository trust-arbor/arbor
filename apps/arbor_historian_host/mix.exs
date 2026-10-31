Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.Historian.Host.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_historian_host,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r"^test/support/"],
      deps: deps()
    ]
  end

  # Product composition only. The canonical Historian application owns its tree.
  def application, do: [extra_applications: [:logger]]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Product runtime and authority bindings precede canonical Historian.
      {:arbor_kernel_runtime, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_persistence_host, in_umbrella: true},
      {:arbor_historian, "~> 0.1.0", path: "../../packages/arbor_historian", env: Mix.env()},
      {:arbor_capabilities, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities", runtime: false, env: Mix.env()},
      {:arbor_persistence, "~> 0.1.0-dev",
       path: "../../packages/arbor_persistence", env: Mix.env()},
      {:arbor_persistence_sql, "~> 0.1.0-dev",
       path: "../../packages/arbor_persistence_sql", env: Mix.env()},
      {:arbor_signals, "~> 0.2.0-dev",
       path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
      {:ecto_sql, "~> 3.10", only: :test, runtime: false},
      {:ecto_sqlite3, "~> 0.18", only: :test, runtime: false},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end
end
