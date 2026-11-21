defmodule Arbor.Capabilities.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_capabilities,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r"^test/support/"],
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: deps(),
      description:
        "Capability authorization, cryptographic identity and caller-owned authority for OTP",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Arbor.Security.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_kernel, "~> 2.0.0-dev", path: "../arbor_kernel"},
      {:arbor_persistence, "~> 0.1.0-dev", path: "../arbor_persistence"},
      {:arbor_custody, "~> 0.1.0-dev", path: "../arbor_custody"},
      {:arbor_support, "~> 0.1.0-dev", path: "../arbor_support"},
      {:arbor_oauth, "~> 0.1.0-dev", path: "../arbor_oauth"},
      {:arbor_capabilities_oidc, "~> 0.1.0-dev",
       path: "../arbor_capabilities_oidc", optional: true, runtime: false},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug_crypto, "~> 2.0"},
      {:typed_struct, "~> 0.3", runtime: false},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end
end
