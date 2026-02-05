defmodule Arbor.Monitor.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/trust-arbor/arbor_monitor"

  def project do
    [
      app: :arbor_monitor,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_pattern: "*_test.exs"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon],
      mod: {Arbor.Monitor.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:recon, "~> 2.5"},
      # Dev/test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    BEAM runtime intelligence for Arbor. Provides process monitoring,
    memory tracking, scheduler utilization, and anomaly detection
    using recon and streaming statistics (EWMA/Welford).
    """
  end

  defp package do
    [
      name: "arbor_monitor",
      licenses: ["MIT"],
      links: %{
        "GitLab" => @source_url
      },
      maintainers: ["Trust Arbor Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Monitor",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
