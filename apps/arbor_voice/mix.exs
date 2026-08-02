Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborVoice.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_voice,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Voice.Application, []}
    ]
  end

  # L8 — headless engagement-substrate consumer for voice, the sibling of
  # arbor_dashboard. Deps are the packet's exact list; arbor_orchestrator +
  # arbor_agent pin the level at L8 (1 + their L7).
  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_comms, in_umbrella: true},
      {:arbor_llm, in_umbrella: true},
      {:arbor_ai, in_umbrella: true},
      {:arbor_orchestrator, in_umbrella: true},
      {:arbor_agent, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:mint, "~> 1.9"},
      {:mint_web_socket, "~> 1.0"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
