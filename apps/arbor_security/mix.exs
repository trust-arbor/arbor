Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborSecurity.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_security,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: deps(),
      docs: [main: "Arbor.Security", extras: []]
    ]
  end

  # Product composition is passive. The canonical Capabilities application is
  # the sole owner of the historical Security authority supervisor and modules.
  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      # KernelRuntime must establish the product boot binding before Core starts.
      {:arbor_kernel_runtime, in_umbrella: true},
      {:arbor_capabilities, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities", env: Mix.env()},
      {:arbor_capabilities_signals, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities_signals", runtime: false, env: Mix.env()},
      {:arbor_capabilities_oidc, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities_oidc",
       optional: true,
       runtime: false,
       env: Mix.env()},
      {:arbor_kernel, "~> 2.0.0-dev", path: "../../packages/arbor_kernel", env: Mix.env()},
      {:arbor_support, "~> 0.1.0-dev", path: "../../packages/arbor_support", env: Mix.env()},
      {:arbor_custody, "~> 0.1.0-dev", path: "../../packages/arbor_custody", env: Mix.env()},
      {:arbor_oauth, "~> 0.1.0-dev", path: "../../packages/arbor_oauth", env: Mix.env()},
      {:arbor_signals, "~> 0.2.0-dev",
       path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug_crypto, "~> 2.0"},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end
end
