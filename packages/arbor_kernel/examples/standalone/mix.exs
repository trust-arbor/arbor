defmodule KernelStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :kernel_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: [{:arbor_kernel, "~> 2.0.0-dev", path: System.fetch_env!("KERNEL_PACKAGE_PATH")}],
      releases: [kernel_standalone_consumer: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KernelStandaloneConsumer.Application, []}
    ]
  end
end
