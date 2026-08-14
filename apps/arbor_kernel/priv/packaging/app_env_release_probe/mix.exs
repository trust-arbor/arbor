# Probe-only fixture; not a production release.
# Relative path deps are illustrative. The driver rewrites a temp copy to
# absolute paths of the tracked owner apps.
defmodule ArborKernelAppEnvProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_kernel_app_env_probe,
      version: "0.0.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:arbor_kernel, path: "../../.."},
      {:arbor_contracts, path: "../../../../arbor_contracts"},
      {:arbor_common, path: "../../../../arbor_common"},
      {:arbor_signals, path: "../../../../arbor_signals"},
      {:arbor_monitor, path: "../../../../arbor_monitor"}
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
