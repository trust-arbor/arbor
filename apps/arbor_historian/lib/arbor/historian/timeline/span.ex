defmodule Arbor.Historian.Timeline.Span do
  @moduledoc """
  Defines a time range and optional filters for timeline queries.

  A Span describes what slice of the history to reconstruct — by time range,
  streams, categories, types, agent, or correlation chain.
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct do
    @typedoc "A time-bounded, optionally filtered query span"

    field :from, DateTime.t(), enforce: true
    field :to, DateTime.t(), enforce: true
    field :streams, [String.t()], default: []
    field :categories, [atom()], default: []
    field :types, [atom()], default: []
    field :agent_id, String.t()
    field :correlation_id, String.t()
  end

  @doc """
  Create a new Span from a keyword list.

  ## Required
  - `:from` - Start time
  - `:to` - End time

  ## Optional
  - `:streams` - Restrict to specific stream IDs
  - `:categories` - Filter by category atoms
  - `:types` - Filter by type atoms
  - `:agent_id` - Filter by agent
  - `:correlation_id` - Filter by correlation chain
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      from: Keyword.fetch!(opts, :from),
      to: Keyword.fetch!(opts, :to),
      streams: Keyword.get(opts, :streams, []),
      categories: Keyword.get(opts, :categories, []),
      types: Keyword.get(opts, :types, []),
      agent_id: Keyword.get(opts, :agent_id),
      correlation_id: Keyword.get(opts, :correlation_id)
    }
  end

  @doc """
  Create a span covering the last N minutes from now.
  """
  @spec last_minutes(pos_integer(), keyword()) :: t()
  def last_minutes(minutes, opts) do
    now = DateTime.utc_now()
    from = DateTime.add(now, -minutes * 60, :second)
    new(Keyword.merge(opts, from: from, to: now))
  end

  @doc """
  Create a span covering the last N hours from now.
  """
  @spec last_hours(pos_integer(), keyword()) :: t()
  def last_hours(hours, opts) do
    last_minutes(hours * 60, opts)
  end

  @doc """
  Check whether a DateTime falls within this span's time range.
  """
  @spec contains?(t(), DateTime.t()) :: boolean()
  def contains?(%__MODULE__{from: from, to: to}, %DateTime{} = dt) do
    DateTime.compare(dt, from) in [:gt, :eq] and
      DateTime.compare(dt, to) in [:lt, :eq]
  end

  @doc """
  Return the duration of this span in seconds.
  """
  @spec duration_seconds(t()) :: integer()
  def duration_seconds(%__MODULE__{from: from, to: to}) do
    DateTime.diff(to, from, :second)
  end
end
