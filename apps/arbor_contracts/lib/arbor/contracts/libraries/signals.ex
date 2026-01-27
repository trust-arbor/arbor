defmodule Arbor.Contracts.Libraries.Signals do
  @moduledoc """
  Public API contract for the Arbor.Signals library.

  Defines the facade interface for the unified observability system.

  ## Quick Start

      :ok = Arbor.Signals.emit(:activity, :agent_started, %{agent_id: "agent_001"})

  ## Signal Categories

  | Category | Purpose |
  |----------|---------|
  | `:activity` | Business events |
  | `:security` | Security events |
  | `:metrics` | Numeric measurements |
  | `:logs` | Log entries |
  | `:alerts` | Actionable alerts |
  """

  @type category ::
          :activity
          | :security
          | :metrics
          | :traces
          | :logs
          | :alerts
          | :custom

  @type signal_type :: atom()
  @type signal_id :: String.t()
  @type subscription_id :: String.t()
  @type pattern :: String.t()
  @type signal :: map()
  @type handler :: (signal() -> :ok | {:error, term()})

  @type emit_opts :: [
          source: String.t(),
          cause_id: signal_id() | nil,
          correlation_id: String.t() | nil,
          metadata: map(),
          async: boolean()
        ]

  @type subscribe_opts :: [
          async: boolean(),
          buffer_size: non_neg_integer(),
          filter: (signal() -> boolean())
        ]

  @doc """
  Emit a signal for the given category and type with data and options.
  """
  @callback emit_signal_for_category_and_type(
              category(),
              signal_type(),
              data :: map(),
              emit_opts()
            ) :: :ok | {:error, term()}

  @doc """
  Emit a preconstructed signal directly to the signal bus.
  """
  @callback emit_preconstructed_signal(signal()) :: :ok | {:error, term()}

  @doc """
  Subscribe to signals matching a pattern with a handler function.
  """
  @callback subscribe_to_signals_matching_pattern(
              pattern(),
              handler(),
              subscribe_opts()
            ) :: {:ok, subscription_id()} | {:error, term()}

  @doc """
  Unsubscribe from signals by subscription ID.
  """
  @callback unsubscribe_from_signals_by_subscription_id(subscription_id()) ::
              :ok | {:error, :not_found}

  @doc """
  Get a signal by its ID.
  """
  @callback get_signal_by_id(signal_id()) :: {:ok, signal()} | {:error, :not_found}

  @doc """
  Query signals with filters.
  """
  @callback query_signals_with_filters(filters :: keyword()) ::
              {:ok, [signal()]} | {:error, term()}

  @doc """
  Get recent signals from the in-memory buffer.
  """
  @callback get_recent_signals_from_buffer(opts :: keyword()) ::
              {:ok, [signal()]} | {:error, term()}

  @doc """
  Start the signals system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the signals system is healthy.
  """
  @callback healthy?() :: boolean()

  @optional_callbacks [
    emit_preconstructed_signal: 1,
    get_signal_by_id: 1,
    query_signals_with_filters: 1,
    get_recent_signals_from_buffer: 1
  ]
end
