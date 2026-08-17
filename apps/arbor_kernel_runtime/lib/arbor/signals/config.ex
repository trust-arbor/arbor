defmodule Arbor.Signals.Config do
  @moduledoc """
  Owner-scoped application env for Signals.

  Values live under `config :arbor_kernel, signals: [...]`. Durable-sink,
  security, crypto, and identity seams default to `nil` (disabled). Umbrella
  runtime or tests inject concrete modules; this library never hardcodes those
  providers.

  ## Configuration Keys

      config :arbor_kernel,
        signals: [
          authorizer: Arbor.Signals.Adapters.CapabilityAuthorizer,
          restricted_topics: [:security, :identity],
          security_sync_subscribers: %{},
          durable_sink_module: nil,
          security_module: nil,
          crypto_module: nil,
          identity_registry_module: nil,
          channel_auto_rotate_interval_ms: 86_400_000,
          channel_rotate_on_leave: true,
          relay_enabled: true,
          relay_batch_interval_ms: 50,
          relay_max_batch_size: 500,
          relay_category_rate_limit: 100,
          relay_node_rate_limit: 1000
        ]
  """

  require Logger

  @default_authorizer Arbor.Signals.Adapters.CapabilityAuthorizer
  @default_restricted_topics [:security, :identity]
  @default_security_sync_subscribers %{}
  @security_sync_event_pattern ~r/^[a-z][a-z0-9_]*$/
  @default_auto_rotate_interval_ms 86_400_000
  @default_rotate_on_leave true
  @default_channels_module Arbor.Signals.Channels
  @default_checkpoint_interval_ms 60_000
  @default_category_rate_limit 100
  @default_node_rate_limit 1000
  @default_batch_interval_ms 50
  @default_max_batch_size 500

  @doc """
  Return the configured subscription authorizer module.

  Defaults to `CapabilityAuthorizer`, which forwards bounded subscribe
  checks to the configured authorization provider.
  Test env overrides to `OpenAuthorizer` for isolated testing.
  """
  @spec authorizer() :: module()
  def authorizer do
    configured = get(:authorizer, @default_authorizer)

    if configured == Arbor.Signals.Adapters.OpenAuthorizer and
         not get(:allow_open_authorizer, false) do
      Logger.warning(
        "OpenAuthorizer rejected without allow_open_authorizer flag, using CapabilityAuthorizer"
      )

      @default_authorizer
    else
      configured
    end
  end

  @doc """
  Return the list of restricted topics that require authorization.

  Defaults to `[:security, :identity]`.
  """
  @spec restricted_topics() :: [atom()]
  def restricted_topics do
    get(:restricted_topics, @default_restricted_topics)
  end

  @doc false
  @spec security_sync_owner(atom(), atom()) :: {:ok, atom()} | :error
  def security_sync_owner(role, event) when is_atom(role) and is_atom(event) do
    subscribers = get(:security_sync_subscribers, @default_security_sync_subscribers)

    with true <- is_map(subscribers),
         %{owner: owner, events: events} <- Map.get(subscribers, role),
         true <- is_atom(owner) and owner not in [nil, true, false],
         true <- valid_security_sync_events?(events),
         true <- event in events do
      {:ok, owner}
    else
      _ -> :error
    end
  end

  def security_sync_owner(_role, _event), do: :error

  @doc """
  Whether any well-formed security-sync role is configured.

  An empty or malformed subscriber map is local-only: stores must start
  without cluster subscriptions. A configured role still fails closed
  if that owner cannot subscribe.
  """
  @spec security_sync_transport_configured?() :: boolean()
  def security_sync_transport_configured? do
    subscribers = get(:security_sync_subscribers, @default_security_sync_subscribers)

    is_map(subscribers) and
      Enum.any?(subscribers, fn {role, _entry} -> security_sync_role_configured?(role) end)
  end

  @doc false
  @spec security_sync_role_configured?(atom()) :: boolean()
  def security_sync_role_configured?(role)
      when is_atom(role) and role not in [nil, true, false] do
    subscribers = get(:security_sync_subscribers, @default_security_sync_subscribers)

    with true <- is_map(subscribers),
         %{owner: owner, events: events} <- Map.get(subscribers, role),
         true <- is_atom(owner) and owner not in [nil, true, false],
         true <- valid_security_sync_events?(events) do
      true
    else
      _ -> false
    end
  end

  def security_sync_role_configured?(_role), do: false

  defp valid_security_sync_events?(events) do
    is_list(events) and events != [] and Enum.all?(events, &valid_security_sync_event?/1) and
      length(events) == length(Enum.uniq(events))
  end

  defp valid_security_sync_event?(event) when is_atom(event) and event not in [nil, true, false],
    do: Regex.match?(@security_sync_event_pattern, Atom.to_string(event))

  defp valid_security_sync_event?(_event), do: false

  @doc """
  Return the configured auto-rotation interval for channel keys in milliseconds.

  Defaults to 86,400,000 (24 hours).
  """
  @spec channel_auto_rotate_interval_ms() :: pos_integer()
  def channel_auto_rotate_interval_ms do
    get(:channel_auto_rotate_interval_ms, @default_auto_rotate_interval_ms)
  end

  @doc """
  Return whether to automatically rotate channel keys when a member leaves.

  Defaults to `true`. When enabled, departing members cannot read future
  messages since the key changes after they leave.
  """
  @spec channel_rotate_on_leave?() :: boolean()
  def channel_rotate_on_leave? do
    get(:channel_rotate_on_leave, @default_rotate_on_leave)
  end

  @doc """
  Module implementing `Arbor.Signals.Contracts.DurableSink`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec durable_sink_module() :: module() | nil | term()
  def durable_sink_module, do: get(:durable_sink_module, nil)

  @doc """
  Module implementing `Arbor.Signals.Contracts.Authorization`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec security_module() :: module() | nil | term()
  def security_module, do: get(:security_module, nil)

  @doc """
  Module implementing `Arbor.Signals.Contracts.Crypto`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec crypto_module() :: module() | nil | term()
  def crypto_module, do: get(:crypto_module, nil)

  @doc """
  Module implementing `Arbor.Signals.Contracts.IdentityKeys`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec identity_registry_module() :: module() | nil | term()
  def identity_registry_module, do: get(:identity_registry_module, nil)

  @doc "Whether Signals starts its optional supervised children (default true)."
  @spec start_children?() :: boolean() | nil
  def start_children?, do: get(:start_children, true)

  @doc "Whether the security telemetry-to-signal bridge attaches (default true)."
  @spec security_telemetry_bridge?() :: boolean() | nil
  def security_telemetry_bridge?, do: get(:security_telemetry_bridge, true)

  @doc "Whether the cross-node relay is enabled (default true)."
  @spec relay_enabled?() :: boolean() | nil
  def relay_enabled?, do: get(:relay_enabled, true)

  @doc "Per-category relay tokens per second (default 100)."
  @spec relay_category_rate_limit() :: non_neg_integer()
  def relay_category_rate_limit, do: get(:relay_category_rate_limit, @default_category_rate_limit)

  @doc "Per-node ingress relay rate limit (default 1000)."
  @spec relay_node_rate_limit() :: non_neg_integer()
  def relay_node_rate_limit, do: get(:relay_node_rate_limit, @default_node_rate_limit)

  @doc "Relay batch flush interval in milliseconds (default 50)."
  @spec relay_batch_interval_ms() :: pos_integer()
  def relay_batch_interval_ms, do: get(:relay_batch_interval_ms, @default_batch_interval_ms)

  @doc "Relay maximum outbound batch size (default 500)."
  @spec relay_max_batch_size() :: pos_integer()
  def relay_max_batch_size, do: get(:relay_max_batch_size, @default_max_batch_size)

  @doc "Checkpoint adapter module, or `nil`."
  @spec checkpoint_module() :: module() | nil
  def checkpoint_module, do: get(:checkpoint_module, nil)

  @doc "Checkpoint store backend, or `nil`."
  @spec checkpoint_store() :: term()
  def checkpoint_store, do: get(:checkpoint_store, nil)

  @doc "Checkpoint save interval in milliseconds (default 60_000)."
  @spec checkpoint_interval_ms() :: pos_integer()
  def checkpoint_interval_ms, do: get(:checkpoint_interval_ms, @default_checkpoint_interval_ms)

  @doc "Channel decrypt module (default `Arbor.Signals.Channels`)."
  @spec channels_module() :: module()
  def channels_module, do: get(:channels_module, @default_channels_module)

  @namespace :signals

  defp get(key, default) when is_atom(key) do
    case Application.fetch_env(:arbor_kernel, @namespace) do
      :error -> default
      {:ok, config} -> fetch_namespace_key(config, key, default)
    end
  end

  defp fetch_namespace_key(config, key, default) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.get(config, key, default)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp fetch_namespace_key(%{__struct__: _}, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp fetch_namespace_key(%{} = config, key, default) do
    Map.get(config, key, default)
  end

  defp fetch_namespace_key(_config, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp malformed_namespace_message do
    "Arbor.Signals.Config malformed :arbor_kernel :signals namespace"
  end
end
