defmodule Arbor.Signals.Config do
  @moduledoc """
  Runtime configuration for the signal bus.

  Resolves authorizer module and restricted topics from application config,
  with sensible defaults for backward compatibility.

  ## Configuration Keys

      config :arbor_signals,
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
  """

  require Logger

  @default_authorizer Arbor.Signals.Adapters.CapabilityAuthorizer
  @default_restricted_topics [:security, :identity]
  @default_security_sync_subscribers %{}
  @security_sync_event_pattern ~r/^[a-z][a-z0-9_]*$/
  @default_auto_rotate_interval_ms 86_400_000
  @default_rotate_on_leave true

  @doc """
  Return the configured subscription authorizer module.

  Defaults to `CapabilityAuthorizer`, which forwards bounded subscribe
  checks to the configured authorization provider.
  Test env overrides to `OpenAuthorizer` for isolated testing.
  """
  @spec authorizer() :: module()
  def authorizer do
    configured = Application.get_env(:arbor_signals, :authorizer, @default_authorizer)

    if configured == Arbor.Signals.Adapters.OpenAuthorizer and
         not Application.get_env(:arbor_signals, :allow_open_authorizer, false) do
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
    Application.get_env(:arbor_signals, :restricted_topics, @default_restricted_topics)
  end

  @doc false
  @spec security_sync_owner(atom(), atom()) :: {:ok, atom()} | :error
  def security_sync_owner(role, event) when is_atom(role) and is_atom(event) do
    subscribers =
      Application.get_env(
        :arbor_signals,
        :security_sync_subscribers,
        @default_security_sync_subscribers
      )

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
    Application.get_env(
      :arbor_signals,
      :channel_auto_rotate_interval_ms,
      @default_auto_rotate_interval_ms
    )
  end

  @doc """
  Return whether to automatically rotate channel keys when a member leaves.

  Defaults to `true`. When enabled, departing members cannot read future
  messages since the key changes after they leave.
  """
  @spec channel_rotate_on_leave?() :: boolean()
  def channel_rotate_on_leave? do
    Application.get_env(:arbor_signals, :channel_rotate_on_leave, @default_rotate_on_leave)
  end

  @doc """
  Module implementing `Arbor.Signals.Contracts.DurableSink`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec durable_sink_module() :: module() | nil | term()
  def durable_sink_module do
    Application.get_env(:arbor_signals, :durable_sink_module, nil)
  end

  @doc """
  Module implementing `Arbor.Signals.Contracts.Authorization`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec security_module() :: module() | nil | term()
  def security_module do
    Application.get_env(:arbor_signals, :security_module, nil)
  end

  @doc """
  Module implementing `Arbor.Signals.Contracts.Crypto`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec crypto_module() :: module() | nil | term()
  def crypto_module do
    Application.get_env(:arbor_signals, :crypto_module, nil)
  end

  @doc """
  Module implementing `Arbor.Signals.Contracts.IdentityKeys`, or `nil`.

  Standalone and test default is `nil`. Umbrella runtime or tests inject
  a concrete module; this library never hardcodes that provider.
  """
  @spec identity_registry_module() :: module() | nil | term()
  def identity_registry_module do
    Application.get_env(:arbor_signals, :identity_registry_module, nil)
  end
end
