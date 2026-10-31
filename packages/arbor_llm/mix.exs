defmodule Arbor.LLM.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_llm,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r"^test/support/"],
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: deps(),
      description:
        "Bounded model clients, streaming, OAuth, tool loops and composable call plugs",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib priv mix.exs README.md LICENSE)
      ]
    ]
  end

  def application do
    [
      mod: {Arbor.LLM.Application, []},
      extra_applications: [:logger, :crypto, :xmerl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      kernel_dependency(),
      support_dependency(),
      oauth_dependency(),
      signals_dependency(),
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:plug_cowboy, "~> 2.9"},
      # Req chooses Plug.Test support at compile time; keep Plug direct.
      {:plug, "~> 1.14"},
      {:ranch, "~> 2.3"},
      {:cowboy, "~> 2.19"},
      {:req, "~> 0.7.5"},
      {:finch, "~> 0.24"},
      {:mint, "~> 1.9.3"},
      {:llm_db, "~> 2026.9.6"},
      {:req_llm, "~> 1.25.0"},
      {:boundary, "~> 0.10", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp kernel_dependency do
    case System.get_env("ARBOR_KERNEL_PATH") do
      nil -> {:arbor_kernel, "~> 2.0.0-dev"}
      path -> {:arbor_kernel, "~> 2.0.0-dev", path: path, override: true}
    end
  end

  defp support_dependency do
    case System.get_env("ARBOR_SUPPORT_PATH") do
      nil -> {:arbor_support, "~> 0.1.0-dev"}
      path -> {:arbor_support, "~> 0.1.0-dev", path: path, override: true}
    end
  end

  defp oauth_dependency do
    case System.get_env("ARBOR_OAUTH_PATH") do
      nil -> {:arbor_oauth, "~> 0.1.0-dev"}
      path -> {:arbor_oauth, "~> 0.1.0-dev", path: path, override: true}
    end
  end

  defp signals_dependency do
    case System.get_env("ARBOR_SIGNALS_PATH") do
      nil -> {:arbor_signals, "~> 0.2.0-dev", runtime: false}
      path -> {:arbor_signals, "~> 0.2.0-dev", path: path, override: true, runtime: false}
    end
  end
end
