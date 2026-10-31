defmodule Arbor.Commands.PlatformInventory.Scope do
  @moduledoc """
  Reviewed v2 successor to the original nine-application E0A source scope.

  Persistence, Security, Trust, Historian and LLM retain complete families across
  package and host owners. Exact relocated sources retain their actual consumer
  owners without selecting those consumers' other sources. The
  physical roots are explicit, so an old embedded copy cannot silently join
  the package's source set. Historical v1 E0A receipts are not rewritten.
  """

  @umbrella_apps ~w(
    arbor_cartographer arbor_llm_host arbor_security arbor_persistence_host
    arbor_shell arbor_sandbox arbor_historian_host arbor_trust_host
  )
  @package_apps ~w(
    arbor_capabilities arbor_capabilities_signals arbor_trust arbor_historian arbor_llm
    arbor_persistence arbor_persistence_sql arbor_persistence_eventstore
  )
  @relocated_sources %{
    "apps/arbor_orchestrator/lib/arbor/llm/arbor_actions_executor.ex" => "arbor_orchestrator",
    "apps/arbor_commands/lib/mix/tasks/arbor.login.ex" => "arbor_commands",
    "apps/arbor_commands/lib/mix/tasks/arbor.oauth.login.ex" => "arbor_commands",
    "apps/arbor_commands/lib/mix/tasks/arbor/llm/free.ex" => "arbor_commands",
    "apps/arbor_commands/lib/arbor/commands/llm/disclosure_prompt.ex" => "arbor_commands"
  }
  @whole_source_apps Enum.sort(@umbrella_apps ++ @package_apps)
  @platform_apps Enum.sort(Enum.uniq(@whole_source_apps ++ Map.values(@relocated_sources)))
  @roots %{
    "apps" => MapSet.new(@umbrella_apps),
    "packages" => MapSet.new(@package_apps)
  }
  @max_path_bytes 4_096

  @spec platform_apps() :: [String.t()]
  def platform_apps, do: @platform_apps

  @spec whole_source_apps() :: [String.t()]
  def whole_source_apps, do: @whole_source_apps

  @spec relocated_source_paths() :: [String.t()]
  def relocated_source_paths, do: @relocated_sources |> Map.keys() |> Enum.sort()

  @spec source_app(term()) :: {:ok, String.t()} | {:error, atom()}
  def source_app(path) when is_binary(path) and byte_size(path) <= @max_path_bytes do
    segments = String.split(path, "/", trim: false)

    if canonical?(path, segments) do
      case Map.fetch(@relocated_sources, path) do
        {:ok, app} -> {:ok, app}
        :error -> admit_source(segments)
      end
    else
      {:error, :outside_platform_scope}
    end
  rescue
    _ -> {:error, :outside_platform_scope}
  end

  def source_app(_), do: {:error, :outside_platform_scope}

  defp canonical?(path, segments) do
    path != "" and String.valid?(path) and not String.contains?(path, [<<0>>, "\\"]) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp admit_source([scope, app, "lib" | rest]) when rest != [] do
    cond do
      not MapSet.member?(Map.get(@roots, scope, MapSet.new()), app) ->
        {:error, :outside_platform_scope}

      not String.ends_with?(List.last(rest), ".ex") ->
        {:error, :not_elixir_source}

      true ->
        {:ok, app}
    end
  end

  defp admit_source(_), do: {:error, :outside_platform_scope}
end
