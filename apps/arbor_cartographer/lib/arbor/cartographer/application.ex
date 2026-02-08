defmodule Arbor.Cartographer.Application do
  @moduledoc """
  Application module for Arbor.Cartographer.

  Starts the Cartographer supervision tree which includes:
  - CapabilityRegistry - Local capability storage
  - Scout - Hardware introspection agent

  ## Configuration

  Configure via application environment:

      config :arbor_cartographer,
        introspection_interval: :timer.minutes(5),
        load_update_interval: :timer.seconds(30),
        custom_tags: [:production]

  Or via environment variables:

      CARTOGRAPHER_INTROSPECTION_INTERVAL=300000
      CARTOGRAPHER_LOAD_UPDATE_INTERVAL=30000
      CARTOGRAPHER_CUSTOM_TAGS=production,gpu_optimized
  """

  use Application

  @impl true
  def start(_type, _args) do
    opts = build_opts()
    Arbor.Cartographer.Supervisor.start_link(opts)
  end

  defp build_opts do
    []
    |> add_introspection_interval()
    |> add_load_update_interval()
    |> add_custom_tags()
  end

  defp add_introspection_interval(opts) do
    interval =
      case System.get_env("CARTOGRAPHER_INTROSPECTION_INTERVAL") do
        nil -> Application.get_env(:arbor_cartographer, :introspection_interval)
        val -> String.to_integer(val)
      end

    if interval, do: Keyword.put(opts, :introspection_interval, interval), else: opts
  end

  defp add_load_update_interval(opts) do
    interval =
      case System.get_env("CARTOGRAPHER_LOAD_UPDATE_INTERVAL") do
        nil -> Application.get_env(:arbor_cartographer, :load_update_interval)
        val -> String.to_integer(val)
      end

    if interval, do: Keyword.put(opts, :load_update_interval, interval), else: opts
  end

  defp add_custom_tags(opts) do
    tags =
      case System.get_env("CARTOGRAPHER_CUSTOM_TAGS") do
        nil ->
          Application.get_env(:arbor_cartographer, :custom_tags, [])

        val ->
          val
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.to_atom/1)
      end

    if tags != [], do: Keyword.put(opts, :custom_tags, tags), else: opts
  end
end
