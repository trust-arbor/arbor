defmodule Mix.Tasks.Arbor.Recompile do
  @shortdoc "Hot-reload changed modules on the running Arbor server"
  @moduledoc """
  Hot-reloads compiled Arbor modules whose on-disk BEAM differs from the code
  loaded by the running server.

      $ mix arbor.recompile

  Mix compiles local source before running this task. Because the development
  server shares that build directory, the task reconciles its loaded Arbor
  modules against those newly compiled BEAMs.
  """
  use Mix.Task

  alias Arbor.Common.CodeReloader
  alias Mix.Tasks.Arbor.Helpers, as: Config

  @rpc_timeout 120_000
  @max_reported_modules 50
  @max_reported_failures 20

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    node = Config.full_node_name()
    Mix.shell().info("Reconciling loaded Arbor modules on #{node}...")

    with :ok <- load_reloader(node),
         summary when is_map(summary) <-
           :rpc.call(node, CodeReloader, :reload_changed, [], @rpc_timeout) do
      report(summary)
    else
      {:error, reason} -> fail("Could not load the remote reloader: #{inspect(reason)}")
      {:badrpc, reason} -> fail("RPC failed: #{inspect(reason)}")
      other -> fail("Unexpected recompile result: #{inspect(other)}")
    end
  end

  defp load_reloader(node) do
    case :rpc.call(node, :code, :soft_purge, [CodeReloader], @rpc_timeout) do
      true ->
        case :rpc.call(node, :code, :load_file, [CodeReloader], @rpc_timeout) do
          {:module, CodeReloader} -> :ok
          {:error, reason} -> {:error, reason}
          {:badrpc, _reason} = error -> error
          other -> {:error, {:unexpected_load_result, other}}
        end

      false ->
        {:error, :reloader_old_code_in_use}

      {:badrpc, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_purge_result, other}}
    end
  end

  defp report(%{
         checked: checked,
         unchanged: unchanged,
         reloaded: reloaded,
         failures: failures
       })
       when is_integer(checked) and is_integer(unchanged) and is_list(reloaded) and
              is_list(failures) do
    Mix.shell().info(
      "Checked #{checked} loaded module(s): #{length(reloaded)} reloaded, " <>
        "#{unchanged} unchanged."
    )

    reloaded
    |> Enum.take(@max_reported_modules)
    |> Enum.each(&Mix.shell().info("  reloaded #{inspect(&1)}"))

    report_omitted(reloaded, @max_reported_modules, "reloaded module")

    if failures == [] do
      :ok
    else
      failures
      |> Enum.take(@max_reported_failures)
      |> Enum.each(fn {subject, reason} ->
        Mix.shell().error("  failed #{inspect(subject)}: #{inspect(reason)}")
      end)

      report_omitted(failures, @max_reported_failures, "failure")
      fail("Hot reload was incomplete; restart the server before continuing.")
    end
  end

  defp report(other), do: fail("Invalid recompile summary: #{inspect(other)}")

  defp report_omitted(entries, limit, label) do
    omitted = max(length(entries) - limit, 0)

    if omitted > 0 do
      Mix.shell().info("  ... #{omitted} additional #{label}(s) omitted")
    end
  end

  defp fail(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
