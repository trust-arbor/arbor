defmodule Arbor.OAuth.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_oauth,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: deps(),
      description: "Bounded OAuth acquisition protocols and HTTP transport for Elixir",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  # Resource lifetimes belong to the host. Loading the package starts no pool.
  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.7.5", runtime: false},
      {:finch, "~> 0.24", runtime: false},
      {:mint, "~> 1.9 and >= 1.9.3", runtime: false},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end
end
