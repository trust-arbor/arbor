defmodule LLMStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :llm_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_kernel, "~> 2.0.0-dev",
         path: System.get_env("ARBOR_KERNEL_PATH") || "../../../arbor_kernel", override: true},
        {:arbor_support, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_SUPPORT_PATH") || "../../../arbor_support", override: true},
        {:arbor_oauth, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_OAUTH_PATH") || "../../../arbor_oauth", override: true},
        {:arbor_signals, "~> 0.2.0-dev",
         path: System.get_env("ARBOR_SIGNALS_PATH") || "../../../arbor_signals",
         override: true,
         runtime: false},
        {:arbor_llm, "~> 0.1.0",
         path: System.get_env("ARBOR_LLM_PATH") || "../..", override: true},
        {:llm_db, "~> 2026.9.6"}
      ],
      releases: [
        llm_standalone_consumer: [include_erts: true, applications: [arbor_signals: :load]]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
