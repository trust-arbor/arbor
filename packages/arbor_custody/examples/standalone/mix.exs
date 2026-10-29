defmodule CustodyStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :custody_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:arbor_custody, "~> 0.1.0-dev", path: System.fetch_env!("CUSTODY_PACKAGE_PATH")}],
      releases: [custody_standalone_consumer: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CustodyStandaloneConsumer.Application, []}
    ]
  end
end
