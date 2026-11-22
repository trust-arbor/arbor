Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.KernelRuntime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/trust-arbor/arbor_monitor"

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_kernel_runtime,
      version: @version,
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [
        default: [
          type: :strict,
          check: [aliases: true]
        ]
      ],
      deps: deps(),
      package: package(),
      docs: docs(),
      test_pattern: "*_test.exs",
      test_coverage: [
        threshold: 90,
        ignore_modules: [
          Mix.Tasks.Arbor.Apps,
          Mix.Tasks.Arbor.Attach,
          Mix.Tasks.Arbor.Config,
          Mix.Tasks.Arbor.Eval,
          Mix.Tasks.Arbor.Helpers,
          Mix.Tasks.Arbor.Logs,
          Mix.Tasks.Arbor.Recompile,
          Mix.Tasks.Arbor.Restart,
          Mix.Tasks.Arbor.Start,
          Mix.Tasks.Arbor.Status,
          Mix.Tasks.Arbor.Stop
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      included_applications: [:arbor_signals],
      mod: {Arbor.KernelRuntime.Application, []},
      env: [
        arbor_feature: Arbor.KernelRuntime.Feature,
        arbor_feature_metadata: %{
          id: :core,
          requires: [],
          dependency_role: :fixed_host,
          contribution_scope: :direct_application_entrypoint,
          snapshot_required_keys: [:start_profile, :profile_admission],
          public_child_ids: [
            Arbor.KernelRuntime.BootProfileBinding,
            Arbor.KernelRuntime.ProviderGate,
            Arbor.Common.Application,
            Arbor.Signals.Application,
            Arbor.Monitor.Application
          ],
          sources: %{
            application: %{
              path: "apps/arbor_kernel_runtime/lib/arbor/kernel_runtime/application.ex",
              sha256: "6f2a075b1f38b82fdb64e9ee3941b312bbc5c832c497749c58a244e800884255"
            },
            gate_builder: %{
              path: "apps/arbor_kernel_runtime/lib/arbor/kernel_runtime.ex",
              sha256: "c76e75f02d094cdfecd50c4bad169976185e00ba996a2cc99e14da87ab9c4210"
            },
            gate_declaration: %{
              path: "apps/arbor_kernel_runtime/lib/arbor/kernel_runtime/provider_gate.ex",
              sha256: "46bfd8ba88739f26756fd7004b2d2f5ab20db85e44f66b6e8f5f456a138d66f7"
            },
            direct_global_action_catalog: :no_additional_contribution_declared_here,
            direct_global_uri_provider: :no_additional_contribution_declared_here,
            observation: :source_declaration
          }
        }
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:arbor_capabilities, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities", runtime: false, env: Mix.env()},
      {:arbor_custody, "~> 0.1.0-dev", path: "../../packages/arbor_custody", env: Mix.env()},
      {:arbor_oauth, "~> 0.1.0-dev", path: "../../packages/arbor_oauth", env: Mix.env()},
      {:arbor_support, "~> 0.1.0-dev", path: "../../packages/arbor_support", env: Mix.env()},
      {:arbor_signals, path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
      {:arbor_kernel, "~> 2.0.0-dev", path: "../../packages/arbor_kernel", env: Mix.env()},
      # Two-segment range: req_llm >= 1.25 compiles against Finch >= 0.22
      # (Finch.Pool struct + Finch.Request :pool_tag); a three-segment
      # `~> 0.21.0` here capped resolution below that and broke req_llm.
      {:finch, "~> 0.24", runtime: false},
      {:jason, "~> 1.4"},
      # OAuth's bounded HTTP/1 pool relies on Mint's parser-level response
      # header limit and the response-smuggling fixes released in 1.9.3. That is
      # a floor, not a ceiling: ex_mcp >= 1.7.3 needs mint >= 1.10.2.
      {:mint, "~> 1.9 and >= 1.9.3", override: true, runtime: false},
      {:llm_db, "~> 2026.1", optional: true, runtime: false},
      {:req, "~> 0.5", runtime: false},
      {:zoi, "~> 0.17"},
      {:telemetry, "~> 1.0"},
      {:recon, "~> 2.5", runtime: false},
      {:boundary, "~> 0.10", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "arbor_kernel_runtime",
      files: ~w(lib priv mix.exs README.md),
      licenses: ["MIT"],
      links: %{
        "GitLab" => @source_url
      },
      maintainers: ["Trust Arbor Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Common",
      extras: ["README.md"]
    ]
  end
end
