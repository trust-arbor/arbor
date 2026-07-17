Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborGateway.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_gateway,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Gateway.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_actions, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_memory, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_trust, in_umbrella: true},
      {:plug, "~> 1.14"},
      {:plug_cowboy, "~> 2.6"},
      # WebSocket upgrade for the chat API (Plug.Cowboy + WebSock behaviour).
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_mcp, "1.0.0-rc.4", override: true},
      {:zoi, "~> 0.17"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Arbor.Gateway",
      extras: ["README.md"]
    ]
  end
end
