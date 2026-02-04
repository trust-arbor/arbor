defmodule Mix.Tasks.Sobelow.Umbrella do
  @moduledoc """
  Runs Sobelow security scanner against all Phoenix apps in the umbrella.

  ## Usage

      mix sobelow.umbrella

  Scans arbor_web, arbor_dashboard, and arbor_gateway.
  """
  @shortdoc "Run Sobelow across all Phoenix umbrella apps"

  use Mix.Task

  @phoenix_apps ~w(arbor_web arbor_dashboard arbor_gateway)

  @impl Mix.Task
  def run(_args) do
    results =
      Enum.map(@phoenix_apps, fn app ->
        app_path = Path.join("apps", app)

        if File.dir?(app_path) do
          Mix.shell().info("\n--- Scanning #{app} ---")
          Mix.Task.rerun("sobelow", ["--config", "--root", app_path])
          {:ok, app}
        else
          Mix.shell().info("Skipping #{app} (not found)")
          {:skip, app}
        end
      end)

    failed = Enum.filter(results, &match?({:error, _}, &1))

    if failed != [] do
      Mix.raise("Sobelow found issues in: #{Enum.map_join(failed, ", ", &elem(&1, 1))}")
    end
  end
end
