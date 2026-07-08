defmodule Arbor.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "2.0.0-dev",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :iex, :ex_unit]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.fast": :test,
        "test.all": :test,
        "test.distributed": :test
      ]
    ]
  end

  defp deps do
    [
      # Jido ecosystem — stable 2.0 Hex releases
      {:jido, "~> 2.0", override: true},
      {:jido_action, "~> 2.0", override: true},
      {:jido_signal, "~> 2.0", override: true},
      {:jido_ai, "~> 2.0.0-rc.0", override: true},
      {:req_llm, "~> 1.6", override: true},
      # jido_sandbox has no Hex release yet. Pinned to an immutable ref (not
      # branch: main) — upstream main has since refactored to Jido.Sandbox +
      # removed the VFS/Lua API arbor_sandbox depends on; adopting it is a
      # deliberate migration, not an unreviewed branch float. (Sentinel finding.)
      {:jido_sandbox,
       git: "https://github.com/agentjido/jido_sandbox.git",
       ref: "7fc90881d3c8ca49e769413cc8217344f2b4c29a",
       override: true},
      # ex_mcp on Hex (a temporary `path:` dep is only ever for local testing of unreleased
      # changes — the path has no source on the CI runner). rc.4 adds per-request HTTP handler
      # opts so Arbor's MCP handler can receive verified SignedRequest context.
      {:ex_mcp, "1.0.0-rc.4", override: true},

      # Dev/test tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:local_cluster, "~> 2.1", only: [:test]}

      # These are umbrella apps now, auto-discovered via apps_path
      # arbor_eval — merged into arbor_common as Arbor.Eval + Arbor.Common.SensitiveData
      # arbor_checkpoint — merged into arbor_persistence as Arbor.Persistence.Checkpoint
    ]
  end

  defp aliases do
    [
      setup: ["arbor.setup"],
      quality: [
        "format --check-formatted",
        "credo --strict",
        "deps.unlock --check-unused",
        "xref graph --label compile-connected --fail-above 88"
      ],
      security: ["hex.audit", "deps.audit", "sobelow.umbrella"],
      "test.fast": [
        "test --only fast --exclude database --exclude llm --exclude llm_local --exclude external"
      ],
      "test.all": [
        "test --include llm --include llm_local --include integration --include external --include database"
      ],
      "test.distributed": [
        "test --only distributed --include distributed"
      ],
      "test.unified_llm_conformance": [
        "cmd env MIX_ENV=test mix test apps/arbor_orchestrator/test/arbor/orchestrator/unified_llm apps/arbor_orchestrator/test/arbor/orchestrator/unified_llm_test.exs apps/arbor_orchestrator/test/arbor/orchestrator/conformance/provider_doc_verification_test.exs"
      ]
    ]
  end
end
