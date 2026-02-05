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

  defp deps do
    [
      # Jido ecosystem (path deps for local development)
      {:jido, path: "../jido", override: true},
      {:jido_action, path: "../jido_action", override: true},
      {:jido_ai, path: "../jido_ai", override: true},
      {:jido_behaviortree, path: "../jido_behaviortree", override: true},
      {:jido_character, path: "../jido_character", override: true},
      {:jido_sandbox, path: "../jido_sandbox", override: true},
      {:jido_signal, path: "../jido_signal", override: true},

      # Override to resolve conflicts between jido_ai and jido_character
      {:req_llm, git: "https://github.com/agentjido/req_llm.git", branch: "main", override: true},

      # Dev/test tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}

      # These are umbrella apps now, auto-discovered via apps_path
      # arbor_eval — code quality evaluation (dev/test only via its mix.exs)
      # arbor_checkpoint — generic checkpoint/restore
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict"],
      security: ["hex.audit", "deps.audit", "sobelow.umbrella"],
      "test.fast": ["test --only fast"]
    ]
  end
end
