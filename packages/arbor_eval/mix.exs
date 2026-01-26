defmodule ArborEval.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/trust-arbor/arbor_eval"

  def project do
    [
      app: :arbor_eval,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Hex.pm metadata
      description: description(),
      package: package(),
      docs: docs(),
      # Testing
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Dev/test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Code quality evaluation framework for Elixir projects.
    Provides static analysis checks for idiomatic patterns, PII detection,
    documentation coverage, and AI-readable naming conventions.
    """
  end

  defp package do
    [
      name: "arbor_eval",
      licenses: ["MIT"],
      links: %{
        "GitLab" => @source_url
      },
      maintainers: ["Trust Arbor Team"]
    ]
  end

  defp docs do
    [
      main: "ArborEval",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
