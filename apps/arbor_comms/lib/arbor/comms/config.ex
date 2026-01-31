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
    |> Keyword.get(:log_dir, "~/.arbor/logs/#{channel}_chat")
    |> Path.expand()
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

  # ============================================================================
  # Contact Resolution
  # ============================================================================

  @doc """
  Resolve a friendly name or alias to a channel-specific identifier.

  Takes a name (e.g., "kim", "me", "owner") and a channel (e.g., :email, :signal)
  and returns the channel-specific identifier if found.

  ## Examples

      iex> Config.resolve_contact("kim", :email)
      "kim@example.com"

      iex> Config.resolve_contact("me", :signal)
      "+1XXXXXXXXXX"

      iex> Config.resolve_contact("unknown", :email)
      nil

  If the name looks like a literal identifier (contains "@" for email, starts with "+"
  for signal), returns nil to signal pass-through behavior.
  """
  @spec resolve_contact(String.t(), atom()) :: String.t() | nil
  def resolve_contact(name, channel) when is_binary(name) and is_atom(channel) do
    # If it looks like a literal identifier, don't try to resolve
    if looks_like_identifier?(name, channel) do
      nil
    else
      contacts = Application.get_env(:arbor_comms, :contacts, %{})
      normalized = String.downcase(name)

      # First try direct name match
      case Map.get(contacts, normalized) do
        nil ->
          # Try alias lookup
          find_contact_by_alias(contacts, normalized, channel)

        contact ->
          Map.get(contact, channel)
      end
    end
  end

  def resolve_contact(_, _), do: nil

  @doc """
  Returns the full contacts map.
  """
  @spec contacts() :: map()
  def contacts do
    Application.get_env(:arbor_comms, :contacts, %{})
  end

  # Private helpers for contact resolution

  defp looks_like_identifier?(value, :email), do: String.contains?(value, "@")
  defp looks_like_identifier?(value, :signal), do: String.starts_with?(value, "+")
  defp looks_like_identifier?(_, _), do: false

  defp find_contact_by_alias(contacts, alias_name, channel) do
    Enum.find_value(contacts, fn {_name, contact} ->
      aliases = Map.get(contact, :aliases, [])

      if alias_name in Enum.map(aliases, &String.downcase/1) do
        Map.get(contact, channel)
      end
    end)
  end
end
