Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.Contracts.MixProject do
  use Mix.Project

  @version "2.0.0-dev"
  @source_url "https://github.com/trust-arbor/arbor_contracts"

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_contracts,
      version: @version,
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Contracts and type definitions for the Arbor AI agent orchestration system.
    Provides behaviours, schemas, and protocols for library boundaries.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
