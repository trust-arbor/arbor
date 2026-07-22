Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.LLM.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_llm,
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
      # :xmerl — req_llm requires it (its .app lists it), but Mix's code-path
      # pruning (Elixir >= 1.15) can drop OTP app paths in umbrella mix-task
      # contexts where only the dep's .app declares them. Declaring it here
      # keeps xmerl on the code path wherever arbor_llm starts.
      # Regression: 2026-06-11 `mix arbor.eval` — {:xmerl, {'no such file or
      # directory', 'xmerl.app'}} despite xmerl present in the toolchain.
      extra_applications: [:logger, :xmerl]
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
      {:telemetry, "~> 1.2"},
      # Session 3: req_llm is the transport layer the generic
      # Arbor.LLM.Adapter.ReqLLM dispatches to. Provider routing happens
      # inside req_llm via the model_spec string.
      {:req_llm, "~> 1.6", override: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
