defmodule Arbor.Comms.Config do
  @moduledoc """
  Configuration access for arbor_comms.

  Reads from application env under `:arbor_comms`.
  """

  @doc "Returns whether a given channel is enabled."
  @spec channel_enabled?(atom()) :: boolean()
  def channel_enabled?(channel) do
    channel
    |> channel_config()
    |> Keyword.get(:enabled, false)
  end

  @doc "Returns channel-specific configuration."
  @spec channel_config(atom()) :: keyword()
  def channel_config(channel) do
    Application.get_env(:arbor_comms, channel, [])
  end

  @doc "Returns the poll interval for a channel in milliseconds."
  @spec poll_interval(atom()) :: pos_integer()
  def poll_interval(channel) do
    channel
    |> channel_config()
    |> Keyword.get(:poll_interval_ms, 60_000)
  end

  @doc "Returns the log path for a channel."
  @spec log_path(atom()) :: String.t()
  def log_path(channel) do
    channel
    |> channel_config()
    |> Keyword.get(:log_path, "/tmp/arbor/#{channel}_chat.log")
  end

  @doc "Returns list of configured channel atoms."
  @spec configured_channels() :: [atom()]
  def configured_channels do
    [:signal, :limitless, :email, :voice]
    |> Enum.filter(&channel_enabled?/1)
  end
end
