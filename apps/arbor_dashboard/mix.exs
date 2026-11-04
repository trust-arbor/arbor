Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))
Code.require_file(Path.expand("../../build_support/optional_apps.exs", __DIR__))

defmodule Arbor.Dashboard.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_dashboard,
      version: @version,
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [threshold: 80]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Dashboard.Application, []},
      env: [
        start_children: Mix.env() != :test,
        arbor_feature: Arbor.Dashboard.Feature,
        arbor_feature_metadata: %{
          id: :dashboard,
          requires: [:core],
          dependency_role: :fixed_host_prerequisite,
          contribution_scope: :direct_application_entrypoint,
          snapshot_required_keys: [:start_children],
          public_child_ids: [Phoenix.PubSub.Supervisor, Arbor.Dashboard.Endpoint],
          sources: %{
            application: %{
              path: "apps/arbor_dashboard/lib/arbor_dashboard/application.ex",
              sha256: "38766afcdbb689a24772990b562ab4917f6f9d90da4c57acfad53689ab716117"
            },
            endpoint: %{
              path: "apps/arbor_dashboard/lib/arbor_dashboard/endpoint.ex",
              sha256: "7cf875ae11083cbe461584ccc4b2d6240c49c8bf9a4a8f8dc991e1e2f4ef1c04"
            },
            routes: %{
              owner: Arbor.Dashboard.Router,
              path: "apps/arbor_dashboard/lib/arbor_dashboard/router.ex",
              sha256: "e42d26d7ccae83f5fc66a177d2e043d55cce38993a60d3372ccd441f78f84298",
              coverage: :explicit_routes_with_macro_delegation
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
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_capabilities, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities", runtime: false, env: Mix.env()},
      {:arbor_support, "~> 0.1.0-dev", path: "../../packages/arbor_support", env: Mix.env()},
      {:arbor_signals, path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
      {:conversation_kit, path: "../../packages/conversation_kit"},
      {:conversation_kit_arbor, path: "../../packages/conversation_kit_arbor"},
      # Umbrella dependencies (Level 0-1)
      {:arbor_kernel_runtime, in_umbrella: true},
      {:arbor_web, in_umbrella: true},
      {:arbor_consensus, in_umbrella: true},
      {:arbor_historian, "~> 0.1.0",
       path: "../../packages/arbor_historian", runtime: false, env: Mix.env()},
      {:arbor_historian_host, in_umbrella: true},

      # Level 1
      {:arbor_persistence_host, in_umbrella: true},

      # Level 2
      {:arbor_security, in_umbrella: true},
      {:arbor_agent, in_umbrella: true},
      {:arbor_memory, in_umbrella: true},
      {:arbor_trust, "~> 0.1.0",
       path: "../../packages/arbor_trust", runtime: false, env: Mix.env()},
      {:arbor_trust_host, in_umbrella: true},

      # Standalone
      {:arbor_comms, in_umbrella: true},
      {:arbor_commands, in_umbrella: true},
      {:arbor_orchestrator, in_umbrella: true},
      {:arbor_voice, in_umbrella: true},
      {:arbor_multimedia, in_umbrella: true},

      # Phoenix stack (via arbor_web, but needed for endpoint)
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},

      # Dev/test
      {:tidewave, "~> 0.5", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:floki, "~> 0.37", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
    |> Arbor.OptionalApps.filter_deps()
  end
end
