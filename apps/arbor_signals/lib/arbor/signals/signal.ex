defmodule Arbor.Signals.Signal do
  @moduledoc """
  Represents a signal in the Arbor observability system.

  Signals are immutable events that capture system activity, security events,
  metrics, logs, and alerts. Each signal has a unique ID, category, type,
  timestamp, and associated data.

  ## Categories

  - `:activity` - Business events (agent started, task completed)
  - `:security` - Security events (auth attempts, violations)
  - `:metrics` - Numeric measurements (latency, counts)
  - `:traces` - Distributed tracing spans
  - `:logs` - Log entries with levels
  - `:alerts` - Actionable alerts requiring attention
  - `:custom` - User-defined categories

  ## Usage

      signal = Arbor.Signals.Signal.new(:activity, :agent_started, %{
        agent_id: "agent_001",
        name: "ResearchAgent"
      })
  """

  use TypedStruct

  alias Arbor.Identifiers

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A signal event"

    field(:id, String.t())
    field(:category, atom())
    field(:type, atom())
    field(:data, map(), default: %{})
    field(:timestamp, DateTime.t())
    field(:source, String.t(), enforce: false)
    field(:cause_id, String.t(), enforce: false)
    field(:correlation_id, String.t(), enforce: false)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new signal with the given category, type, and data.

  ## Options

  - `:source` - Identifier of the signal source
  - `:cause_id` - ID of the signal that caused this one
  - `:correlation_id` - ID for correlating related signals
  - `:metadata` - Additional metadata map

  ## Examples

      iex> signal = Arbor.Signals.Signal.new(:activity, :started, %{name: "test"})
      iex> signal.category
      :activity
  """
  @spec new(atom(), atom(), map(), keyword()) :: t()
  def new(category, type, data \\ %{}, opts \\ []) do
    %__MODULE__{
      id: generate_signal_id(),
      category: category,
      type: type,
      data: data,
      timestamp: DateTime.utc_now(),
      source: Keyword.get(opts, :source),
      cause_id: Keyword.get(opts, :cause_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Check if a signal matches the given filters.

  ## Filters

  - `:category` - Match category (atom or list)
  - `:type` - Match type (atom or list)
  - `:source` - Match source string
  - `:since` - Only signals after this DateTime
  - `:until` - Only signals before this DateTime
  - `:correlation_id` - Match correlation ID

  ## Examples

      iex> signal = Arbor.Signals.Signal.new(:activity, :started, %{})
      iex> Arbor.Signals.Signal.matches?(signal, category: :activity)
      true
  """
  @spec matches?(t(), keyword()) :: boolean()
  def matches?(%__MODULE__{} = signal, filters) do
    Enum.all?(filters, fn {key, value} ->
      matches_filter?(signal, key, value)
    end)
  end

  defp matches_filter?(signal, :category, categories) when is_list(categories) do
    signal.category in categories
  end

  defp matches_filter?(signal, :category, category) do
    signal.category == category
  end

  defp matches_filter?(signal, :type, types) when is_list(types) do
    signal.type in types
  end

  defp matches_filter?(signal, :type, type) do
    signal.type == type
  end

  defp matches_filter?(signal, :source, source) do
    signal.source == source
  end

  defp matches_filter?(signal, :correlation_id, correlation_id) do
    signal.correlation_id == correlation_id
  end

  defp matches_filter?(signal, :since, datetime) do
    DateTime.compare(signal.timestamp, datetime) in [:gt, :eq]
  end

  defp matches_filter?(signal, :until, datetime) do
    DateTime.compare(signal.timestamp, datetime) in [:lt, :eq]
  end

  defp matches_filter?(_signal, _key, _value), do: true

  defp generate_signal_id do
    Identifiers.generate_id("sig_")
  end
end
