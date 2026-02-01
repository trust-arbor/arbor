defmodule Arbor.Flow.MixProject do
  use Mix.Project

  @version "2.0.0-dev"

  def project do
    [
      app: :arbor_flow,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Level 0 library - zero umbrella dependencies
  # Only external deps: jason for JSON encoding
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Pure workflow utilities for Arbor: markdown item parsing, index management,
    file watching, and change detection. Level 0 library with zero umbrella deps.
    """
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
