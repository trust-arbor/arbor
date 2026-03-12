defmodule Arbor.Gateway.PreprocessingLog do
  @moduledoc """
  Tracks prompt pre-processing outcomes for feedback and improvement.

  Phase 4 of the Prompt Pre-Processor pipeline. Records the chain of
  classification → intent → verification for each prompt, enabling:

  - Pattern detection (which prompt types fail verification?)
  - Anomaly surfacing (this task took 3x longer than similar ones)
  - Intent extraction quality tracking (did the extracted intent match reality?)

  Uses an ETS table for in-memory storage with optional persistence flush.
  """

  use GenServer

  require Logger

  @table :arbor_preprocessing_log
  @max_entries 1000

  @type entry :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          prompt_hash: String.t(),
          classification: map(),
          intent: map() | nil,
          verification_results: [map()] | nil,
          duration_ms: non_neg_integer() | nil,
          outcome: :pending | :success | :partial | :failure,
          metadata: map()
        }

  # -- Public API --

  @doc """
  Record a new pre-processing entry.

  Called after classification + intent extraction. Verification results
  and outcome can be updated later via `update/2`.
  """
  @spec record(map()) :: {:ok, String.t()} | {:error, term()}
  def record(attrs) when is_map(attrs) do
    if table_exists?() do
      entry = build_entry(attrs)
      :ets.insert(@table, {entry.id, entry})
      maybe_prune()
      {:ok, entry.id}
    else
      {:error, :not_running}
    end
  end

  @doc """
  Update an existing entry with verification results or outcome.
  """
  @spec update(String.t(), map()) :: :ok | {:error, :not_found | :not_running}
  def update(id, updates) when is_binary(id) and is_map(updates) do
    if table_exists?() do
      case :ets.lookup(@table, id) do
        [{^id, entry}] ->
          updated = Map.merge(entry, updates)
          :ets.insert(@table, {id, updated})
          :ok

        [] ->
          {:error, :not_found}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Get an entry by ID.
  """
  @spec get(String.t()) :: {:ok, entry()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    if table_exists?() do
      case :ets.lookup(@table, id) do
        [{^id, entry}] -> {:ok, entry}
        [] -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  List recent entries, newest first.
  """
  @spec recent(keyword()) :: [entry()]
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    if table_exists?() do
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(limit)
    else
      []
    end
  end

  @doc """
  Get statistics about pre-processing outcomes.
  """
  @spec stats() :: map()
  def stats do
    entries = recent(limit: @max_entries)
    total = length(entries)

    if total == 0 do
      %{total: 0, success_rate: 0.0, avg_duration_ms: 0, by_outcome: %{}, by_sensitivity: %{}}
    else
      by_outcome = Enum.frequencies_by(entries, & &1.outcome)

      by_sensitivity =
        Enum.frequencies_by(entries, fn e ->
          get_in(e, [:classification, :overall_sensitivity]) || :unknown
        end)

      durations =
        entries
        |> Enum.map(& &1.duration_ms)
        |> Enum.reject(&is_nil/1)

      avg_duration =
        if durations != [],
          do: div(Enum.sum(durations), length(durations)),
          else: 0

      success_count = Map.get(by_outcome, :success, 0)

      %{
        total: total,
        success_rate: if(total > 0, do: success_count / total, else: 0.0),
        avg_duration_ms: avg_duration,
        by_outcome: by_outcome,
        by_sensitivity: by_sensitivity
      }
    end
  end

  @doc """
  Find entries with similar prompt hashes (for pattern detection).
  """
  @spec similar(String.t()) :: [entry()]
  def similar(prompt_hash) when is_binary(prompt_hash) do
    if table_exists?() do
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {_id, entry} -> entry.prompt_hash == prompt_hash end)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    else
      []
    end
  end

  # -- GenServer --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @impl GenServer
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    {:ok, %{}}
  end

  # -- Private --

  defp build_entry(attrs) do
    %{
      id: Map.get(attrs, :id, generate_id()),
      timestamp: Map.get(attrs, :timestamp, DateTime.utc_now()),
      prompt_hash: Map.get(attrs, :prompt_hash, ""),
      classification: Map.get(attrs, :classification, %{}),
      intent: Map.get(attrs, :intent),
      verification_results: Map.get(attrs, :verification_results),
      duration_ms: Map.get(attrs, :duration_ms),
      outcome: Map.get(attrs, :outcome, :pending),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp generate_id do
    "preproc_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp maybe_prune do
    size = :ets.info(@table, :size)

    if size > @max_entries do
      # Remove oldest entries
      entries =
        @table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_id, e} -> e.timestamp end, {:asc, DateTime})
        |> Enum.take(size - @max_entries)

      Enum.each(entries, fn {id, _} -> :ets.delete(@table, id) end)
    end
  end

  defp table_exists? do
    :ets.whereis(@table) != :undefined
  end
end
