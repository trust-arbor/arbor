defmodule Arbor.Comms.Config do
  @moduledoc """
  Configuration access for arbor_comms.

  Reads from application env under `:arbor_comms`.
  """

  @default_durable_interaction_store_namespace :durable_interactions
  @default_durable_interaction_store_max_data_bytes 65_536
  @default_durable_interaction_store_max_items 1_000
  @default_durable_dispatch_sweep_interval_ms 1_000
  @default_durable_dispatch_startup_delay_ms 0
  @default_durable_dispatch_batch_size 32
  @default_durable_dispatch_retry_base_ms 250
  @default_durable_dispatch_retry_max_ms 30_000
  @default_durable_dispatch_send_timeout_ms 5_000
  @default_durable_dispatch_max_concurrency 4
  @max_durable_dispatch_sweep_interval_ms 300_000
  @max_durable_dispatch_batch_size 100
  @max_durable_dispatch_retry_ms 300_000
  @max_durable_dispatch_send_timeout_ms 30_000
  @max_durable_dispatch_concurrency 32
  @durable_dispatch_keys [
    :sweep_interval_ms,
    :startup_delay_ms,
    :batch_size,
    :retry_base_ms,
    :retry_max_ms,
    :send_timeout_ms,
    :max_concurrency
  ]

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

  # ============================================================================
  # Durable interaction store configuration
  # ============================================================================

  @doc "Returns the configured durable interaction persistence backend, or nil when disabled."
  @spec durable_interaction_store_backend() :: module() | nil | term()
  def durable_interaction_store_backend do
    durable_interaction_store_config()
    |> Keyword.get(:backend)
  end

  @doc "Returns the fixed namespace used for durable interaction records."
  @spec durable_interaction_store_namespace() :: atom() | term()
  def durable_interaction_store_namespace do
    durable_interaction_store_config()
    |> Keyword.get(:namespace, @default_durable_interaction_store_namespace)
  end

  @doc "Returns backend options supplied by configuration for the durable store."
  @spec durable_interaction_store_opts() :: keyword() | term()
  def durable_interaction_store_opts do
    durable_interaction_store_config()
    |> Keyword.get(:opts, [])
  end

  @doc "Returns the closed JSON data byte limit for durable interaction records."
  @spec durable_interaction_store_max_data_bytes() :: pos_integer() | term()
  def durable_interaction_store_max_data_bytes do
    durable_interaction_store_config()
    |> Keyword.get(:max_data_bytes, @default_durable_interaction_store_max_data_bytes)
  end

  @doc "Returns the maximum number of keys returned by durable interaction inventory."
  @spec durable_interaction_store_max_items() :: pos_integer() | term()
  def durable_interaction_store_max_items do
    durable_interaction_store_config()
    |> Keyword.get(:max_items, @default_durable_interaction_store_max_items)
  end

  @doc "Returns the configured interaction adapter registry, failing closed to an empty map."
  @spec interaction_adapters() :: %{optional(atom()) => module()}
  def interaction_adapters do
    case Application.get_env(:arbor_comms, :interaction_adapters, %{}) do
      adapters when is_map(adapters) -> adapters
      _ -> %{}
    end
  end

  @doc "Returns validated timing and capacity controls for durable interaction dispatch."
  @spec durable_interaction_dispatch_config() ::
          {:ok,
           %{
             sweep_interval_ms: pos_integer(),
             startup_delay_ms: non_neg_integer(),
             batch_size: pos_integer(),
             retry_base_ms: pos_integer(),
             retry_max_ms: pos_integer(),
             send_timeout_ms: pos_integer(),
             max_concurrency: pos_integer()
           }}
          | {:error, :invalid_config}
  def durable_interaction_dispatch_config do
    with {:ok, config} <- durable_interaction_dispatch_options() do
      values = %{
        sweep_interval_ms:
          Keyword.get(
            config,
            :sweep_interval_ms,
            @default_durable_dispatch_sweep_interval_ms
          ),
        startup_delay_ms:
          Keyword.get(
            config,
            :startup_delay_ms,
            @default_durable_dispatch_startup_delay_ms
          ),
        batch_size: Keyword.get(config, :batch_size, @default_durable_dispatch_batch_size),
        retry_base_ms:
          Keyword.get(config, :retry_base_ms, @default_durable_dispatch_retry_base_ms),
        retry_max_ms: Keyword.get(config, :retry_max_ms, @default_durable_dispatch_retry_max_ms),
        send_timeout_ms:
          Keyword.get(config, :send_timeout_ms, @default_durable_dispatch_send_timeout_ms),
        max_concurrency:
          Keyword.get(
            config,
            :max_concurrency,
            @default_durable_dispatch_max_concurrency
          )
      }

      if valid_dispatch_config?(values), do: {:ok, values}, else: {:error, :invalid_config}
    end
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

  defp durable_interaction_store_config do
    case Application.get_env(:arbor_comms, :durable_interaction_store, []) do
      config when is_list(config) ->
        if Keyword.keyword?(config), do: config, else: []

      _ ->
        []
    end
  end

  defp durable_interaction_dispatch_options do
    case Application.fetch_env(:arbor_comms, :durable_interaction_dispatch) do
      :error ->
        {:ok, []}

      {:ok, config} when is_list(config) ->
        if Keyword.keyword?(config) do
          keys = Keyword.keys(config)

          if length(keys) == length(Enum.uniq(keys)) and
               Enum.all?(keys, &(&1 in @durable_dispatch_keys)) do
            {:ok, config}
          else
            {:error, :invalid_config}
          end
        else
          {:error, :invalid_config}
        end

      {:ok, _malformed} ->
        {:error, :invalid_config}
    end
  end

  defp valid_dispatch_config?(config) do
    positive_bounded?(
      config.sweep_interval_ms,
      @max_durable_dispatch_sweep_interval_ms
    ) and
      non_negative_bounded?(
        config.startup_delay_ms,
        @max_durable_dispatch_sweep_interval_ms
      ) and
      positive_bounded?(config.batch_size, @max_durable_dispatch_batch_size) and
      positive_bounded?(config.retry_base_ms, @max_durable_dispatch_retry_ms) and
      positive_bounded?(config.retry_max_ms, @max_durable_dispatch_retry_ms) and
      positive_bounded?(
        config.send_timeout_ms,
        @max_durable_dispatch_send_timeout_ms
      ) and
      positive_bounded?(
        config.max_concurrency,
        @max_durable_dispatch_concurrency
      ) and
      config.retry_base_ms <= config.retry_max_ms
  end

  defp positive_bounded?(value, maximum),
    do: is_integer(value) and value > 0 and value <= maximum

  defp non_negative_bounded?(value, maximum),
    do: is_integer(value) and value >= 0 and value <= maximum

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
