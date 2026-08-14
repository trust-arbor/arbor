# Probe-only fixture; not a production application.
# Relative path deps are illustrative. The driver rewrites a temp copy to
# absolute paths of the tracked owner apps.
defmodule ArborKernelStartupFootprintProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_kernel_startup_footprint_probe,
      version: "0.0.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
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
      {:arbor_kernel, path: "../../..", runtime: false},
      {:arbor_contracts, path: "../../../../arbor_contracts", runtime: false},
      {:arbor_common, path: "../../../../arbor_common", runtime: false},
      {:arbor_signals, path: "../../../../arbor_signals", runtime: false},
      {:arbor_monitor, path: "../../../../arbor_monitor", runtime: false},
      {:jason, "~> 1.4"}
    ]
  end
end
