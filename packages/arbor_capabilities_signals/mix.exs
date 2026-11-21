defmodule Arbor.Capabilities.Signals.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_capabilities_signals,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: [
        {:arbor_capabilities, "~> 0.1.0-dev", path: "../arbor_capabilities", runtime: false},
        {:arbor_signals, "~> 0.2.0-dev", path: "../arbor_signals", runtime: false},
        {:boundary, "~> 0.10", runtime: false}
      ],
      description:
        "Explicit Capabilities authorization, crypto and synchronization adapters for Signals",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
