defmodule SupportStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :support_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_support, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_SUPPORT_PATH") || "../..", override: true}
      ],
      releases: [support_standalone_consumer: [include_erts: true]]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
