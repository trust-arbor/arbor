defmodule ArborAgentReleaseGate.MixProject do
  use Mix.Project
  @root Path.expand("../../../..", __DIR__)
  @libraries ~w(arbor_actions arbor_agent arbor_ai arbor_comms arbor_consensus arbor_historian arbor_kernel arbor_kernel_runtime arbor_llm arbor_memory arbor_orchestrator arbor_persistence arbor_sandbox arbor_scheduler arbor_security arbor_shell arbor_trust)a

  def project do
    [
      app: :arbor_agent_release_gate,
      version: "0.1.0",
      lockfile: Path.join(@root, "mix.lock"),
      deps_path: Path.join(@root, "deps"),
      releases: [arbor_agent_release_gate: [applications: Enum.map(@libraries, &{&1, :load})]],
      deps:
        [
          {:jido, "~> 2.0", override: true},
          {:jido_action, "~> 2.0", override: true},
          {:jido_signal, "~> 2.0", override: true},
          {:jido_ai, "~> 2.0.0-rc.0", override: true},
          {:req_llm, "~> 1.6", override: true},
          {:ex_mcp, "1.3.0", override: true},
          {:jido_sandbox,
           git: "https://github.com/agentjido/jido_sandbox.git",
           ref: "7fc90881d3c8ca49e769413cc8217344f2b4c29a",
           override: true}
        ] ++
          Enum.map(@libraries, fn app ->
            {app,
             path: Path.join([@root, "apps", to_string(app)]),
             override: true,
             runtime: false,
             env: :prod}
          end)
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
