defmodule Arbor.LLM.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_llm,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      # Session 1 (pure data extract): zero in-umbrella deps. arbor_common
      # and req_llm get added in later sessions as the orchestration core
      # and the generic adapter land.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
