defmodule Arbor.Checkpoint.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/trust-arbor/arbor_checkpoint"

  def project do
    [
      app: :arbor_checkpoint,
      version: @version,
      elixir: "~> 1.17",
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
    Generic checkpoint/restore library for Elixir processes.
    Provides state persistence patterns with pluggable storage backends,
    retry logic, auto-save scheduling, and recovery mechanisms.
    """
  end

  defp package do
    [
      name: "arbor_checkpoint",
      licenses: ["MIT"],
      links: %{
        "GitLab" => @source_url
      },
      maintainers: ["Trust Arbor Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Checkpoint",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
