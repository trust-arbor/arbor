Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.Trust.Host.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_trust_host,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: paths[:build_path],
      deps_path: paths[:deps_path],
      config_path: "../../config/config.exs",
      lockfile: "../../mix.lock",
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: [
        {:arbor_kernel_runtime, in_umbrella: true},
        {:arbor_security, in_umbrella: true},
        {:arbor_trust, "~> 0.1.0", path: "../../packages/arbor_trust", env: Mix.env()},
        {:arbor_signals, "~> 0.2.0-dev",
         path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
        {:arbor_capabilities, "~> 0.1.0-dev",
         path: "../../packages/arbor_capabilities", runtime: false, env: Mix.env()},
        {:arbor_kernel, "~> 2.0.0-dev", path: "../../packages/arbor_kernel", env: Mix.env()},
        {:arbor_persistence_host, in_umbrella: true, runtime: false},
        {:arbor_persistence_sql, "~> 0.1.0-dev",
         path: "../../packages/arbor_persistence_sql", runtime: false, env: Mix.env()},
        {:phoenix_pubsub, "~> 2.1", runtime: false},
        {:boundary, "~> 0.10", runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
