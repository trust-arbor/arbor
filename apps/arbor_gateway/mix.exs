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
      mod: {Arbor.Gateway.Application, []},
      env: [
        arbor_feature: Arbor.Gateway.Feature,
        arbor_feature_metadata: %{
          id: :gateway,
          requires: [:core],
          dependency_role: :fixed_host_prerequisite,
          contribution_scope: :direct_application_entrypoint,
          snapshot_required_keys: [:mcp_client_enabled, :start_server, :http_admission],
          snapshot_conditional_required_keys: %{
            http_admission: %{
              not_requested: [],
              port_in_use: [:port],
              available: [:port, :bind_ip, :http_idle_timeout_ms, :handler_call_timeout_ms]
            }
          },
          public_child_ids: [
            Arbor.Gateway.MCP.ClientSupervisor,
            Arbor.Gateway.MCP.EndpointRegistry,
            Arbor.Gateway.Chat.LifecycleAuthority,
            {:ranch_embedded_sup, Arbor.Gateway.Router.HTTP}
          ],
          sources: %{
            application: %{
              path: "apps/arbor_gateway/lib/arbor/gateway/application.ex",
              sha256: "def51d6acd2b3ad76a5aef794863317b077956187e6ab568472e3b80175a381b"
            },
            http_options: %{
              path: "apps/arbor_gateway/lib/arbor/gateway/http_server_options.ex",
              sha256: "84cb2ab726ae86b77c06b4c850354a3194631c4612a07af1a20ba8cf860b2eee"
            },
            routes: %{
              owner: Arbor.Gateway.Router,
              path: "apps/arbor_gateway/lib/arbor/gateway/router.ex",
              sha256: "1b96edc4c05841d379698fb3c24c349bf0fa2013e94b9a0f10409a9157aa192b",
              coverage: :top_level_mounts_with_delegation_and_build_guards
            },
            ranch_constructor: %{
              physical_owner: :ranch,
              source: "ranch/src/ranch.erl",
              sha256: "670c017fd5cb1ca3349515f49423e259f364270eeb3fb65f02e4f598d9dcf717"
            },
            direct_global_action_catalog: :no_additional_contribution_declared_here,
            direct_global_uri_provider: :no_additional_contribution_declared_here,
            observation: :source_declaration
          }
        }
      ]
    ]
  end

  defp deps do
    [
      {:arbor_kernel, "~> 2.0.0-dev", path: "../../packages/arbor_kernel", env: Mix.env()},
      {:arbor_comms, in_umbrella: true},
      {:arbor_capabilities, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities", runtime: false, env: Mix.env()},
      {:arbor_support, "~> 0.1.0-dev", path: "../../packages/arbor_support", env: Mix.env()},
      {:arbor_signals, path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
      {:arbor_actions, in_umbrella: true},
      {:arbor_kernel_runtime, in_umbrella: true},
      {:arbor_memory, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_trust, "~> 0.1.0",
       path: "../../packages/arbor_trust", runtime: false, env: Mix.env()},
      {:arbor_trust_host, in_umbrella: true},
      {:plug, "~> 1.14"},
      {:plug_cowboy, "~> 2.6"},
      # WebSocket upgrade for the chat API (Plug.Cowboy + WebSock behaviour).
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_mcp, "1.8.1", override: true},
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
