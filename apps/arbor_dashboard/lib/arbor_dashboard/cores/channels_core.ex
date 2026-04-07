defmodule Arbor.Dashboard.Cores.ChannelsCore do
  @moduledoc """
  Pure display formatters for the channels_live dashboard (Arbor.Comms channels).

  channels_live shows channel registry contents with name and type filters.
  This module owns the formatters and the per-type color mapping.

  ## Functions

  - `type_color/1` — channel type atom → badge color
  - `format_datetime/1` — DateTime → "YYYY-MM-DD HH:MM"
  - `count_stats/1` — channel list → {total, public_count}
  - `show_channel/1` — single channel → display map
  """

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc "Format a single channel for display."
  @spec show_channel(map()) :: map()
  def show_channel(channel) when is_map(channel) do
    type = Map.get(channel, :type)

    %{
      channel_id: Map.get(channel, :channel_id) || Map.get(channel, :id),
      name: Map.get(channel, :name, "—"),
      type: type,
      type_color: type_color(type),
      member_count: Map.get(channel, :member_count, 0),
      created_at: Map.get(channel, :created_at),
      created_at_label: format_datetime(Map.get(channel, :created_at))
    }
  end

  @doc "Compute total + public counts from a channel list."
  @spec count_stats([map()]) :: {non_neg_integer(), non_neg_integer()}
  def count_stats(channels) when is_list(channels) do
    total = length(channels)
    public = Enum.count(channels, &(Map.get(&1, :type) == :public))
    {total, public}
  end

  def count_stats(_), do: {0, 0}

  # ===========================================================================
  # Pure Helpers
  # ===========================================================================

  @doc "Color atom for a channel type badge."
  @spec type_color(atom() | nil) :: atom()
  def type_color(:public), do: :green
  def type_color(:private), do: :purple
  def type_color(:dm), do: :blue
  def type_color(:ops_room), do: :yellow
  def type_color(:group), do: :gray
  def type_color(_), do: :gray

  @doc "Format a DateTime as 'YYYY-MM-DD HH:MM'."
  @spec format_datetime(term()) :: String.t()
  def format_datetime(nil), do: ""
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def format_datetime(other), do: to_string(other)
end
