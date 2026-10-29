defmodule Arbor.Contracts.API.Signals do
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
  @type agent_id :: String.t()

  @typedoc "Closed public failures for retained Memory signal content deletion."
  @type retained_memory_signal_delete_error ::
          :invalid_agent_id
          | :invalid_precondition
          | :store_unavailable
          | :checkpoint_configuration_invalid
          | :checkpoint_unavailable
          | :checkpoint_verification_failed

  @typedoc "Result of bounded exact-agent retained Memory signal content deletion."
  @type retained_memory_signal_delete_result ::
          :ok
          | {:error, {:delete_indeterminate, agent_id()}}
          | {:error, retained_memory_signal_delete_error()}

  @typedoc "Closed public failures for retained Memory signal content absence checks."
  @type retained_memory_signal_absence_error ::
          :invalid_agent_id
          | :invalid_precondition
          | :store_unavailable
          | :checkpoint_configuration_invalid
          | :checkpoint_unavailable
          | :checkpoint_verification_failed

  @typedoc "Result of a bounded exact-agent retained Memory signal content absence check."
  @type retained_memory_signal_absence_result ::
          {:ok, true}
          | {:ok, false}
          | {:error, {:absence_indeterminate, agent_id()}}
          | {:error, retained_memory_signal_absence_error()}

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

  @doc """
  Signal an interrupt to a target.
  """
  @callback interrupt(target_id :: String.t(), reason :: atom(), opts :: keyword()) :: :ok

  @doc """
  Check if a target has been interrupted. Returns interrupt data or false.
  """
  @callback interrupted?(target_id :: String.t()) :: map() | false

  @doc """
  Clear an interrupt for a target.
  """
  @callback clear_interrupt(target_id :: String.t()) :: :ok

  @doc """
  Delete retained `:memory` signal content for exactly one agent id from the
  live Signals Store and its configured checkpoint.

  Optional. Returns `:ok` only after definite live deletion and, when
  checkpointing is configured, definite save/load convergence proving
  absence. Post-dispatch uncertainty returns
  `{:error, {:delete_indeterminate, agent_id}}`. Backend-native details never
  escape.
  """
  @callback delete_retained_memory_signal_content_for_agent(agent_id(), opts :: keyword()) ::
              retained_memory_signal_delete_result()

  @doc """
  Prove whether retained `:memory` signal content for exactly one agent id is
  absent from the live Signals Store and its configured checkpoint.

  Optional and read-only. Returns `{:ok, true}` only when every required
  surface is independently validated target-free. Post-dispatch uncertainty
  returns `{:error, {:absence_indeterminate, agent_id}}`. Backend-native
  details never escape.
  """
  @callback check_retained_memory_signal_content_absent_for_agent(agent_id(), opts :: keyword()) ::
              retained_memory_signal_absence_result()

  @optional_callbacks [
    emit_preconstructed_signal: 1,
    get_signal_by_id: 1,
    query_signals_with_filters: 1,
    get_recent_signals_from_buffer: 1,
    interrupt: 3,
    interrupted?: 1,
    clear_interrupt: 1,
    delete_retained_memory_signal_content_for_agent: 2,
    check_retained_memory_signal_content_absent_for_agent: 2
  ]
end
