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

  @doc "Returns the log directory for a channel's chat logs."
  @spec log_dir(atom()) :: String.t()
  def log_dir(channel) do
    channel
    |> channel_config()
    |> Keyword.get(:log_dir, "/tmp/arbor/#{channel}_chat")
  end

  @doc "Returns the log retention period in days."
  @spec log_retention_days(atom()) :: pos_integer()
  def log_retention_days(channel) do
    channel
    |> channel_config()
    |> Keyword.get(:log_retention_days, 30)
  end

  @doc "Returns list of configured channel atoms."
  @spec configured_channels() :: [atom()]
  def configured_channels do
    [:signal, :limitless, :email, :voice]
    |> Enum.filter(&channel_enabled?/1)
  end

  # ============================================================================
  # Handler Configuration
  # ============================================================================

  @doc "Returns a handler config value with a default."
  @spec handler_config(atom(), term()) :: term()
  def handler_config(key, default \\ nil) do
    Application.get_env(:arbor_comms, :handler, [])
    |> Keyword.get(key, default)
  end

  @doc "Returns whether the message handler is enabled."
  @spec handler_enabled?() :: boolean()
  def handler_enabled? do
    handler_config(:enabled, false)
  end

  @doc "Returns the list of authorized sender identifiers."
  @spec authorized_senders() :: [String.t()]
  def authorized_senders do
    handler_config(:authorized_senders, [])
  end

  @doc "Returns the configured ResponseGenerator module."
  @spec response_generator() :: module() | nil
  def response_generator do
    handler_config(:response_generator)
  end

  @doc "Returns the default channel for routing responses when the origin channel can't send."
  @spec default_response_channel() :: atom()
  def default_response_channel do
    handler_config(:default_response_channel, :signal)
  end

  @doc "Returns the configured ResponseRouter module."
  @spec response_router() :: module()
  def response_router do
    handler_config(:response_router, Arbor.Comms.ResponseRouter)
  end
end
