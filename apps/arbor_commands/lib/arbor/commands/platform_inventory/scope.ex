defmodule Arbor.Commands.PlatformInventory.Scope do
  @moduledoc """
  Reviewed v2 successor to the original nine-application E0A source scope.

  Persistence's former two owners are now the core, SQL, EventStore and host
  owners. Every former production source remains in the selected family. The
  physical roots are explicit, so an old embedded copy cannot silently join
  the package's source set. Historical v1 E0A receipts are not rewritten.
  """

  @umbrella_apps ~w(
    arbor_cartographer arbor_llm arbor_security arbor_persistence_host
    arbor_shell arbor_sandbox arbor_historian arbor_trust
  )
  @package_apps ~w(arbor_persistence arbor_persistence_sql arbor_persistence_eventstore)
  @platform_apps Enum.sort(@umbrella_apps ++ @package_apps)
  @roots %{
    "apps" => MapSet.new(@umbrella_apps),
    "packages" => MapSet.new(@package_apps)
  }
  @max_path_bytes 4_096

  @spec platform_apps() :: [String.t()]
  def platform_apps, do: @platform_apps

  @spec source_app(term()) :: {:ok, String.t()} | {:error, atom()}
  def source_app(path) when is_binary(path) and byte_size(path) <= @max_path_bytes do
    segments = String.split(path, "/", trim: false)

    if canonical?(path, segments) do
      admit_source(segments)
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
