defmodule Arbor.Signals.Store.MemoryPrivacyCore do
  @moduledoc false

  # Pure CRC decisions for retained Memory signal privacy cleanup.
  # No process calls, Application env, or checkpoint I/O.

  alias Arbor.Signals.Signal

  @max_agent_id_bytes 255
  @default_timeout_ms 5_000
  @min_timeout_ms 1
  @max_timeout_ms 60_000

  @type agent_id :: String.t()
  @type class :: :target | :survivor | :non_memory | :ambiguous | :malformed

  @spec validate_agent_id(term()) :: {:ok, agent_id()} | {:error, :invalid_agent_id}
  def validate_agent_id(agent_id) when is_binary(agent_id) do
    byte_size = byte_size(agent_id)

    cond do
      byte_size < 1 or byte_size > @max_agent_id_bytes ->
        {:error, :invalid_agent_id}

      not String.valid?(agent_id) ->
        {:error, :invalid_agent_id}

      true ->
        {:ok, agent_id}
    end
  end

  def validate_agent_id(_), do: {:error, :invalid_agent_id}

  @spec validate_timeout_ms(term()) :: {:ok, pos_integer()} | {:error, :invalid_precondition}
  def validate_timeout_ms(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :timeout_ms) do
        :error ->
          {:ok, @default_timeout_ms}

        {:ok, ms} when is_integer(ms) and ms >= @min_timeout_ms and ms <= @max_timeout_ms ->
          {:ok, ms}

        {:ok, _} ->
          {:error, :invalid_precondition}
      end
    else
      {:error, :invalid_precondition}
    end
  end

  @spec validate_store_shape(term(), term(), term()) :: :ok | {:error, :invalid_precondition}
  def validate_store_shape(signals, order, stats) do
    with :ok <- validate_signals_map(signals),
         :ok <- validate_order_bijection(signals, order),
         :ok <- validate_stats(stats) do
      :ok
    else
      :error -> {:error, :invalid_precondition}
    end
  end

  @spec validate_live_state(term()) :: :ok | {:error, :invalid_precondition}
  def validate_live_state(state) when is_map(state) do
    # Require owner keys before any queue conversion — malformed fixtures must
    # never crash the Store process via :queue.to_list/1 on a non-queue.
    with {:ok, signals} <- fetch_owner_key(state, :signals),
         {:ok, order} <- fetch_owner_key(state, :order),
         {:ok, stats} <- fetch_owner_key(state, :stats),
         true <- :queue.is_queue(order) do
      validate_store_shape(signals, :queue.to_list(order), stats)
    else
      _ ->
        {:error, :invalid_precondition}
    end
  end

  def validate_live_state(_), do: {:error, :invalid_precondition}

  defp fetch_owner_key(state, key) when is_map(state) and is_atom(key) do
    case Map.fetch(state, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  @spec classify_signal(term(), agent_id()) :: class()
  def classify_signal(%Signal{category: :memory, data: data}, agent_id) do
    cond do
      not is_map(data) ->
        :ambiguous

      not Map.has_key?(data, :agent_id) ->
        # Missing atom key (includes string-key-only maps).
        :ambiguous

      true ->
        case Map.fetch(data, :agent_id) do
          {:ok, ^agent_id} ->
            :target

          {:ok, other} when is_binary(other) ->
            :survivor

          {:ok, _non_binary} ->
            :ambiguous
        end
    end
  end

  def classify_signal(%Signal{}, _agent_id), do: :non_memory
  def classify_signal(_, _), do: :malformed

  @spec select_target_ids(map(), agent_id()) ::
          {:ok, [String.t()]} | {:error, :invalid_precondition}
  def select_target_ids(signals, agent_id) when is_map(signals) do
    Enum.reduce_while(signals, {:ok, []}, fn {id, signal}, {:ok, acc} ->
      case classify_signal(signal, agent_id) do
        :target ->
          {:cont, {:ok, [id | acc]}}

        :survivor ->
          {:cont, {:ok, acc}}

        :non_memory ->
          {:cont, {:ok, acc}}

        :ambiguous ->
          {:halt, {:error, :invalid_precondition}}

        :malformed ->
          {:halt, {:error, :invalid_precondition}}
      end
    end)
  end

  def select_target_ids(_, _), do: {:error, :invalid_precondition}

  @spec live_has_target?(map(), agent_id()) ::
          {:ok, boolean()} | {:error, :invalid_precondition}
  def live_has_target?(signals, agent_id) do
    case select_target_ids(signals, agent_id) do
      {:ok, ids} -> {:ok, ids != []}
      {:error, _} = err -> err
    end
  end

  @spec has_exact_target?(map(), agent_id()) :: boolean()
  def has_exact_target?(signals, agent_id) do
    case live_has_target?(signals, agent_id) do
      {:ok, true} -> true
      _ -> false
    end
  end

  @spec drop_targets(map(), [String.t()]) :: map()
  def drop_targets(%{signals: signals, order: order, stats: stats} = state, target_ids)
      when is_list(target_ids) do
    target_set = MapSet.new(target_ids)

    signals2 = Map.drop(signals, target_ids)

    order2 =
      order
      |> :queue.to_list()
      |> Enum.reject(&MapSet.member?(target_set, &1))
      |> :queue.from_list()

    # Stats deliberately unchanged — privacy cleanup must not decrement aggregates.
    %{state | signals: signals2, order: order2, stats: stats}
  end

  @spec build_snapshot(map()) :: map()
  def build_snapshot(%{signals: signals, order: order, stats: stats}) do
    %{
      signals: signals,
      order: :queue.to_list(order),
      stats: stats
    }
  end

  @spec snapshot_fields(map()) ::
          {:ok, map(), list(), map()} | :error
  def snapshot_fields(loaded) when is_map(loaded) do
    # Exactly one atom-or-string representation per required field; no extras.
    with {:ok, signals} <- fetch_exclusive_field(loaded, :signals, "signals"),
         {:ok, order} <- fetch_exclusive_field(loaded, :order, "order"),
         {:ok, stats} <- fetch_exclusive_field(loaded, :stats, "stats"),
         :ok <- reject_extra_top_level_keys(loaded),
         true <- is_map(signals) and is_list(order) and is_map(stats) do
      {:ok, signals, order, stats}
    else
      _ -> :error
    end
  end

  def snapshot_fields(_), do: :error

  defp fetch_exclusive_field(map, atom_key, string_key)
       when is_map(map) and is_atom(atom_key) and is_binary(string_key) do
    has_atom = Map.has_key?(map, atom_key)
    has_string = Map.has_key?(map, string_key)

    cond do
      has_atom and has_string ->
        # Duplicate representation — reject (may hide conflicting content).
        :error

      has_atom ->
        {:ok, Map.fetch!(map, atom_key)}

      has_string ->
        {:ok, Map.fetch!(map, string_key)}

      true ->
        :error
    end
  end

  defp reject_extra_top_level_keys(map) when is_map(map) do
    allowed = MapSet.new([:signals, "signals", :order, "order", :stats, "stats"])

    if Map.keys(map) |> MapSet.new() |> MapSet.subset?(allowed) do
      :ok
    else
      :error
    end
  end

  @spec validate_loaded_snapshot(map(), agent_id()) ::
          {:ok, boolean()} | {:error, :invalid_precondition}
  def validate_loaded_snapshot(loaded, agent_id) do
    with {:ok, signals, order, stats} <- snapshot_fields(loaded),
         :ok <- validate_store_shape(signals, order, stats),
         {:ok, has_target?} <- live_has_target?(signals, agent_id) do
      {:ok, has_target?}
    else
      :error -> {:error, :invalid_precondition}
      {:error, _} = err -> err
    end
  end

  @spec snapshots_equal?(map(), map()) :: boolean()
  def snapshots_equal?(approved, loaded) do
    case snapshot_fields(loaded) do
      {:ok, l_signals, l_order, l_stats} ->
        approved.signals == l_signals and approved.order == l_order and approved.stats == l_stats

      :error ->
        false
    end
  end

  @spec prove_delete_convergence(map(), map(), map(), agent_id()) :: :ok | :failed
  def prove_delete_convergence(state2, approved, loaded, agent_id) do
    with {:ok, false} <- validate_loaded_snapshot(loaded, agent_id),
         true <- snapshots_equal?(approved, loaded),
         false <- has_exact_target?(state2.signals, agent_id) do
      :ok
    else
      _ -> :failed
    end
  end

  defp validate_signals_map(signals) when is_map(signals) do
    Enum.reduce_while(signals, :ok, fn {id, signal}, :ok ->
      cond do
        not is_binary(id) ->
          {:halt, :error}

        not match?(%Signal{}, signal) ->
          {:halt, :error}

        signal.id != id ->
          {:halt, :error}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_signals_map(_), do: :error

  defp validate_order_bijection(signals, order) when is_list(order) do
    map_ids = Map.keys(signals)
    map_size = map_size(signals)

    cond do
      length(order) != map_size ->
        :error

      length(order) != length(Enum.uniq(order)) ->
        :error

      not Enum.all?(order, &is_binary/1) ->
        :error

      MapSet.new(order) != MapSet.new(map_ids) ->
        :error

      true ->
        :ok
    end
  end

  defp validate_order_bijection(_, _), do: :error

  defp validate_stats(%{
         total_stored: stored,
         total_expired: expired,
         total_evicted: evicted
       })
       when is_integer(stored) and stored >= 0 and is_integer(expired) and expired >= 0 and
              is_integer(evicted) and evicted >= 0 do
    :ok
  end

  defp validate_stats(_), do: :error
end
