defmodule Arbor.Consensus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/arbor-framework/arbor_consensus"

  def project do
    [
      app: :arbor_consensus,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        threshold: 90,
        ignore_modules: [
          Arbor.Consensus.TestHelpers,
          Arbor.Consensus.TestHelpers.AlwaysApproveBackend,
          Arbor.Consensus.TestHelpers.AlwaysRejectBackend,
          Arbor.Consensus.TestHelpers.FailingBackend,
          Arbor.Consensus.TestHelpers.SlowBackend,
          Arbor.Consensus.TestHelpers.TestEventSink,
          Arbor.Consensus.TestHelpers.TestExecutor,
          Arbor.Consensus.TestHelpers.AllowAllAuthorizer,
          Arbor.Consensus.TestHelpers.DenyAllAuthorizer,
          Arbor.Consensus.TestHelpers.TestEventLog,
          Arbor.Consensus.TestHelpers.FailingExecutor
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Arbor.Consensus.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella dependencies
      {:arbor_common, in_umbrella: true},
      {:arbor_checkpoint, in_umbrella: true},
      {:arbor_contracts, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_shell, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},

      # Core dependencies
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.4"},

      # Dev/test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp description do
    """
    Pure deliberation engine for multi-perspective consensus on system changes.
    Pluggable evaluator backends, authorization, and execution behaviours.
    """
  end

  defp package do
    [
      name: "arbor_consensus",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Arbor Framework Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Consensus",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
