defmodule Mix.Tasks.Arbor.Llm.Free do
  @shortdoc "List admitted OpenCode Zen free-tier models"
  @moduledoc """
  List the OpenCode Zen free-tier models Arbor admits.

  The list is derived from recorded eval evidence, not vendor claims.
  Re-run `mix arbor.eval.opencode_zen` to refresh it.

  Prints the data-disclosure warning (prompts, included context, and
  command output go to OpenCode's API; Arbor makes no privacy guarantees;
  do not use for sensitive data) before the admitted list.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("")
    Mix.shell().info(Arbor.LLM.OpenCodeZen.listing())
    Mix.shell().info("Acknowledge (required before the first request):")
    Mix.shell().info("  mix arbor.doctor --configure")
    Mix.shell().info("")
  end
end
