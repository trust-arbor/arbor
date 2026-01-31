defmodule Arbor.Signals.Config do
  @moduledoc """
  Runtime configuration for the signal bus.

  Resolves authorizer module and restricted topics from application config,
  with sensible defaults for backward compatibility.

  ## Configuration Keys

      config :arbor_signals,
        authorizer: Arbor.Signals.Adapters.OpenAuthorizer,
        restricted_topics: [:security, :identity]
  """

  @default_authorizer Arbor.Signals.Adapters.OpenAuthorizer
  @default_restricted_topics [:security, :identity]

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
end
