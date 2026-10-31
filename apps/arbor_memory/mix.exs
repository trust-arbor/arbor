Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborMemory.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_memory,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Memory.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_capabilities, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities", runtime: false, env: Mix.env()},
      {:arbor_support, "~> 0.1.0-dev", path: "../../packages/arbor_support", env: Mix.env()},
      {:arbor_persistence, path: "../../packages/arbor_persistence", env: Mix.env()},
      {:arbor_persistence_sql, path: "../../packages/arbor_persistence_sql", env: Mix.env()},
      {:arbor_signals, path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
      {:arbor_kernel_runtime, in_umbrella: true},
      {:arbor_persistence_host, in_umbrella: true},
      {:arbor_historian, "~> 0.1.0",
       path: "../../packages/arbor_historian", runtime: false, env: Mix.env()},
      {:arbor_historian_host, in_umbrella: true},
      {:arbor_ai, in_umbrella: true},
      {:arbor_llm, in_umbrella: true},
      {:arbor_trust, "~> 0.1.0",
       path: "../../packages/arbor_trust", runtime: false, env: Mix.env()},
      {:arbor_trust_host, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Arbor.Memory",
      extras: ["README.md"]
    ]
  end
end
