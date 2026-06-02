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
      # Session 2 (behavioral core): arbor_contracts for the Pipeline.Response
      # and AI.RuntimeContract/Capabilities types ToolLoop and ProviderCatalog
      # reference; arbor_common for PromptSanitizer, AgentTelemetry.Store, and
      # ActionRegistry ToolLoop + ArborActionsExecutor reference. req_llm
      # comes in a later session with the generic adapter.
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:req, "~> 0.5"},
      # Session 3: req_llm is the transport layer the generic
      # Arbor.LLM.Adapter.ReqLLM dispatches to. Provider routing happens
      # inside req_llm via the model_spec string.
      {:req_llm, "~> 1.6", override: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
