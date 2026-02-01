defmodule Arbor.Signals.Config do
  @moduledoc """
  Runtime configuration for the signal bus.

  Resolves authorizer module and restricted topics from application config,
  with sensible defaults for backward compatibility.

  ## Configuration Keys

      config :arbor_signals,
        authorizer: Arbor.Signals.Adapters.OpenAuthorizer,
        restricted_topics: [:security, :identity],
        channel_auto_rotate_interval_ms: 86_400_000,
        channel_rotate_on_leave: true
  """

  @default_authorizer Arbor.Signals.Adapters.OpenAuthorizer
  @default_restricted_topics [:security, :identity]
  @default_auto_rotate_interval_ms 86_400_000
  @default_rotate_on_leave true

  @doc """
  Return the configured subscription authorizer module.

  Defaults to `OpenAuthorizer` which allows all subscriptions.
  """
  @spec authorizer() :: module()
  def authorizer do
    Application.get_env(:arbor_signals, :authorizer, @default_authorizer)
  end

  @doc """
  Return the list of restricted topics that require authorization.

  Defaults to `[:security, :identity]`.
  """
  @spec restricted_topics() :: [atom()]
  def restricted_topics do
    Application.get_env(:arbor_signals, :restricted_topics, @default_restricted_topics)
  end

  @doc """
  Return the configured auto-rotation interval for channel keys in milliseconds.

  Defaults to 86,400,000 (24 hours).
  """
  @spec channel_auto_rotate_interval_ms() :: pos_integer()
  def channel_auto_rotate_interval_ms do
    Application.get_env(:arbor_signals, :channel_auto_rotate_interval_ms, @default_auto_rotate_interval_ms)
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
end
