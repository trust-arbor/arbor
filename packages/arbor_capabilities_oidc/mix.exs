defmodule Arbor.CapabilitiesOIDC.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_capabilities_oidc,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: deps(),
      description: "Bounded OpenID Connect protocols with caller-owned identity and cache policy",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      oauth_dependency(),
      {:jason, "~> 1.4"},
      {:joken, "~> 2.7", runtime: false},
      {:plug_crypto, "~> 2.0", runtime: false},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end

  defp oauth_dependency do
    case System.get_env("ARBOR_OAUTH_PATH") do
      nil -> {:arbor_oauth, "~> 0.1.0-dev"}
      path -> {:arbor_oauth, "~> 0.1.0-dev", path: path, override: true}
    end
  end
end
