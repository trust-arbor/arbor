defmodule Mix.Tasks.Arbor.TddUplift do
  @shortdoc "Run the TDD-uplift smoke pipeline against the running server"
  @moduledoc """
  Smoke-tests the software-factory orchestrator by running the
  `tdd_uplift_log_redactor.dot` pipeline against the live `arbor.start`
  server.

      $ mix arbor.tdd_uplift

  Grants three narrow capabilities to `agent_tdd_uplift`, executes the
  DOT pipeline, and reports whether the generated test passed or failed.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(_args) do
    server = Config.require_server!()

    Mix.shell().info("[arbor.tdd_uplift] Server: #{server}")
    Mix.shell().info("[arbor.tdd_uplift] Granting caps to agent_tdd_uplift…")

    runner_script =
      Path.expand("apps/arbor_scheduler/priv/pipelines/run_tdd_uplift.exs")

    case Config.rpc(server, Code, :eval_file, [runner_script]) do
      nil ->
        Mix.shell().error("[arbor.tdd_uplift] RPC failed (badrpc)")

      {result, _bindings} ->
        Mix.shell().info("\n[arbor.tdd_uplift] Result: #{inspect(result, pretty: true)}")
    end
  end
end
