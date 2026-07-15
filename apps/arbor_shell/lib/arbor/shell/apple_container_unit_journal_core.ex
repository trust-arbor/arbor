defmodule Arbor.Shell.AppleContainerUnitJournalCore do
  @moduledoc """
  Pure CRC reducer for a durable Apple Container unit-intent journal.

  Before a future production worker may issue `container create`, Shell will
  durably persist a reserved unit name. Active records survive crashes until the
  unit owner or a startup reconciler has positively proven exact absence. This
  core decides reserve/complete transitions and returns persistence effects as
  data only — a later imperative shell interprets them.

  All functions are pure: no File/IO, GenServer, ETS, Application config,
  Logger, System time, DateTime, randomness, process references, crypto
  generation, or other library facades. Time and tokens are injected by the
  caller.
  """

  @schema_version 1
  @max_active 1_024
  # JSON-safe integer ceiling (2^53 - 1). Larger generation values fail closed
  # before arithmetic so huge decoded JSON integers cannot overflow counters.
  @max_generation 9_007_199_254_740_991
  @max_map_keys 16
  @max_execution_id_bytes 256
  @unit_name_prefix "arbor-v1-"
  @unit_name_hex_bytes 32
  @token_hex_bytes 64

  @unit_name_re ~r/\Aarbor-v1-[0-9a-f]{32}\z/
  @token_re ~r/\A[0-9a-f]{64}\z/

  # Closed journal surface (atom form). String aliases accepted only when the
  # atom form is absent — never both.
  @logical_journal_keys [:schema_version, :generation, :active]
  @allowed_journal_keys MapSet.new(
                          @logical_journal_keys ++
                            Enum.map(@logical_journal_keys, &Atom.to_string/1)
                        )

  @logical_state_keys [:schema_version, :generation, :by_name]

  @logical_record_keys [:unit_name, :execution_id, :token, :reserved_at_ms]
  @allowed_record_keys MapSet.new(
                         @logical_record_keys ++
                           Enum.map(@logical_record_keys, &Atom.to_string/1)
                       )

  @type record :: %{
          unit_name: String.t(),
          execution_id: String.t(),
          token: String.t(),
          reserved_at_ms: non_neg_integer()
        }

  @type state :: %{
          schema_version: 1,
          generation: non_neg_integer(),
          by_name: %{optional(String.t()) => record()}
        }

  @type effect :: {:persist_snapshot, map()}

  @doc false
  @spec limits() :: %{max_active: pos_integer(), max_generation: pos_integer()}
  def limits, do: %{max_active: @max_active, max_generation: @max_generation}

  @doc """
  Construct an empty journal (`schema_version` 1, `generation` 0, no actives).
  """
  @spec new() :: {:ok, state()}
  def new, do: {:ok, empty_state()}

  @doc """
  Construct journal state from a closed external snapshot.

  Accepts atom- or string-keyed maps (never both aliases for the same logical
  field). Rejects unknown keys, duplicate aliases, malformed records,
  unsupported `schema_version`, and over-capacity active collections.
  """
  @spec new(term()) :: {:ok, state()} | {:error, term()}
  def new(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(
             input,
             @allowed_journal_keys,
             @logical_journal_keys,
             :journal
           ),
         {:ok, schema_version} <- fetch_schema_version(input),
         {:ok, generation} <- fetch_generation(input),
         {:ok, active_list} <- fetch_active_list(input),
         {:ok, by_name} <- normalize_active_records(active_list),
         :ok <- validate_generation_consistency(generation, by_name) do
      {:ok,
       %{
         schema_version: schema_version,
         generation: generation,
         by_name: by_name
       }}
    end
  end

  def new(_), do: {:error, :invalid_journal}

  @doc """
  Reserve a unit intent.

  Requires a closed attrs map with `unit_name`, `execution_id`, `token`, and
  injected `reserved_at_ms`. Rejects duplicate unit_name / execution_id /
  token, invalid fields, and capacity. On success increments `generation`
  exactly once and returns a single `{:persist_snapshot, snapshot}` effect
  carrying the exact complete JSON-clean snapshot to persist.
  """
  @spec reserve(state(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def reserve(state, attrs) do
    with :ok <- require_state(state),
         :ok <-
           validate_closed_keys(
             attrs,
             @allowed_record_keys,
             @logical_record_keys,
             :reserve
           ),
         {:ok, record} <- normalize_record(attrs),
         :ok <- reject_capacity(state),
         :ok <- reject_generation_ceiling(state),
         :ok <- reject_duplicate_name(state, record.unit_name),
         :ok <- reject_duplicate_execution_id(state, record.execution_id),
         :ok <- reject_duplicate_token(state, record.token) do
      new_state = %{
        state
        | generation: state.generation + 1,
          by_name: Map.put(state.by_name, record.unit_name, record)
      }

      {:ok, new_state, persist_effect(new_state)}
    end
  end

  @doc """
  Complete (remove) an active intent only when both `unit_name` and `token`
  match exactly.

  Unknown name, wrong token, malformed inputs, and replay fail closed without
  changing state. Successful completion increments `generation` exactly once
  and returns the exact persist-snapshot effect.
  """
  @spec complete(state(), term(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def complete(state, unit_name, token) do
    with :ok <- require_state(state),
         {:ok, unit_name} <- validate_unit_name(unit_name),
         {:ok, token} <- validate_token(token),
         {:ok, existing} <- fetch_active(state, unit_name),
         :ok <- match_token(existing.token, token),
         :ok <- reject_generation_ceiling(state) do
      new_state = %{
        state
        | generation: state.generation + 1,
          by_name: Map.delete(state.by_name, unit_name)
      }

      {:ok, new_state, persist_effect(new_state)}
    end
  end

  @doc """
  Return all active intent records sorted by `unit_name` bytewise.

  Never decides that an entry is absent or safe to delete — recovery listing
  only; absence proof remains an imperative shell concern.
  """
  @spec recovery_entries(state()) :: [record()] | {:error, term()}
  def recovery_entries(state) do
    with :ok <- require_state(state) do
      sorted_records(state)
    end
  end

  @doc """
  Convert journal state to a deterministic JSON-clean canonical snapshot.

  Keys are strings; `active` is sorted by `unit_name` bytewise. Suitable for
  durable persistence and round-trip through `new/1`.
  """
  @spec show(term()) :: map() | {:error, :invalid_journal_state}
  def show(state) do
    with :ok <- require_state(state) do
      snapshot(state)
    end
  end

  # --- Construction helpers ---------------------------------------------------

  defp empty_state do
    %{
      schema_version: @schema_version,
      generation: 0,
      by_name: %{}
    }
  end

  defp require_state(
         %{
           schema_version: @schema_version,
           generation: generation,
           by_name: by_name
         } = state
       )
       when is_integer(generation) and generation >= 0 and generation <= @max_generation and
              is_map(by_name) do
    with true <- Map.keys(state) |> MapSet.new() |> MapSet.equal?(MapSet.new(@logical_state_keys)),
         true <- map_size(by_name) <= @max_active,
         {:ok, normalized_by_name} <- normalize_active_records(Map.values(by_name)),
         true <- normalized_by_name == by_name,
         :ok <- validate_generation_consistency(generation, by_name) do
      :ok
    else
      _ -> {:error, :invalid_journal_state}
    end
  end

  defp require_state(_), do: {:error, :invalid_journal_state}

  defp fetch_schema_version(input) do
    case fetch_field(input, :schema_version) do
      :error ->
        {:error, :missing_schema_version}

      {:ok, @schema_version} ->
        {:ok, @schema_version}

      {:ok, version} when is_integer(version) ->
        {:error, {:unsupported_schema_version, version}}

      {:ok, _other} ->
        {:error, :invalid_schema_version}
    end
  end

  defp fetch_generation(input) do
    case fetch_field(input, :generation) do
      :error ->
        {:error, :missing_generation}

      {:ok, generation}
      when is_integer(generation) and generation >= 0 and generation <= @max_generation ->
        {:ok, generation}

      {:ok, generation} when is_integer(generation) and generation > @max_generation ->
        {:error, :generation_too_large}

      {:ok, _other} ->
        {:error, :invalid_generation}
    end
  end

  defp fetch_active_list(input) do
    case fetch_field(input, :active) do
      :error ->
        {:error, :missing_active}

      {:ok, active} when is_list(active) ->
        if length(active) > @max_active do
          {:error, :journal_at_capacity}
        else
          {:ok, active}
        end

      {:ok, _other} ->
        {:error, :invalid_active}
    end
  end

  defp validate_generation_consistency(generation, by_name) do
    if generation >= map_size(by_name) do
      :ok
    else
      {:error, :invalid_generation}
    end
  end

  defp normalize_active_records(active_list) do
    active_list
    |> Enum.reduce_while({:ok, %{}, MapSet.new(), MapSet.new()}, fn
      entry, {:ok, by_name, execution_ids, tokens} ->
        case normalize_record(entry) do
          {:ok, record} ->
            cond do
              Map.has_key?(by_name, record.unit_name) ->
                {:halt, {:error, :duplicate_unit_name}}

              MapSet.member?(execution_ids, record.execution_id) ->
                {:halt, {:error, :duplicate_execution_id}}

              MapSet.member?(tokens, record.token) ->
                {:halt, {:error, :duplicate_token}}

              true ->
                {:cont,
                 {:ok, Map.put(by_name, record.unit_name, record),
                  MapSet.put(execution_ids, record.execution_id),
                  MapSet.put(tokens, record.token)}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      _entry, acc ->
        {:halt, acc}
    end)
    |> case do
      {:ok, by_name, _execution_ids, _tokens} -> {:ok, by_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_record(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(
             input,
             @allowed_record_keys,
             @logical_record_keys,
             :record
           ),
         {:ok, unit_name} <- fetch_unit_name(input),
         {:ok, execution_id} <- fetch_execution_id(input),
         {:ok, token} <- fetch_token(input),
         {:ok, reserved_at_ms} <- fetch_reserved_at_ms(input) do
      {:ok,
       %{
         unit_name: unit_name,
         execution_id: execution_id,
         token: token,
         reserved_at_ms: reserved_at_ms
       }}
    end
  end

  defp normalize_record(_), do: {:error, :invalid_record}

  defp fetch_unit_name(input) do
    case fetch_field(input, :unit_name) do
      :error -> {:error, :missing_unit_name}
      {:ok, value} -> validate_unit_name(value)
    end
  end

  defp fetch_execution_id(input) do
    case fetch_field(input, :execution_id) do
      :error -> {:error, :missing_execution_id}
      {:ok, value} -> validate_execution_id(value)
    end
  end

  defp fetch_token(input) do
    case fetch_field(input, :token) do
      :error -> {:error, :missing_token}
      {:ok, value} -> validate_token(value)
    end
  end

  defp fetch_reserved_at_ms(input) do
    case fetch_field(input, :reserved_at_ms) do
      :error -> {:error, :missing_reserved_at_ms}
      {:ok, value} -> validate_reserved_at_ms(value)
    end
  end

  # --- Field validators -------------------------------------------------------

  defp validate_unit_name(name) when is_binary(name) do
    cond do
      not String.valid?(name) ->
        {:error, :invalid_unit_name}

      byte_size(name) != byte_size(@unit_name_prefix) + @unit_name_hex_bytes ->
        {:error, :invalid_unit_name}

      not String.starts_with?(name, @unit_name_prefix) ->
        {:error, :invalid_unit_name}

      not Regex.match?(@unit_name_re, name) ->
        {:error, :invalid_unit_name}

      true ->
        {:ok, name}
    end
  end

  defp validate_unit_name(_), do: {:error, :invalid_unit_name}

  defp validate_execution_id(id) when is_binary(id) do
    size = byte_size(id)

    cond do
      not String.valid?(id) ->
        {:error, :invalid_execution_id}

      size < 1 or size > @max_execution_id_bytes ->
        {:error, :invalid_execution_id}

      String.contains?(id, ["/", "\\", <<0>>]) ->
        {:error, :invalid_execution_id}

      has_control_char?(id) ->
        {:error, :invalid_execution_id}

      has_whitespace?(id) ->
        {:error, :invalid_execution_id}

      true ->
        {:ok, id}
    end
  end

  defp validate_execution_id(_), do: {:error, :invalid_execution_id}

  defp validate_token(token) when is_binary(token) do
    cond do
      not String.valid?(token) ->
        {:error, :invalid_token}

      byte_size(token) != @token_hex_bytes ->
        {:error, :invalid_token}

      not Regex.match?(@token_re, token) ->
        {:error, :invalid_token}

      true ->
        {:ok, token}
    end
  end

  defp validate_token(_), do: {:error, :invalid_token}

  defp validate_reserved_at_ms(ms) when is_integer(ms) and ms >= 0, do: {:ok, ms}
  defp validate_reserved_at_ms(_), do: {:error, :invalid_reserved_at_ms}

  # --- Transition guards ------------------------------------------------------

  defp reject_capacity(%{by_name: by_name}) do
    if map_size(by_name) >= @max_active do
      {:error, :journal_at_capacity}
    else
      :ok
    end
  end

  defp reject_generation_ceiling(%{generation: generation})
       when is_integer(generation) and generation >= @max_generation do
    {:error, :generation_too_large}
  end

  defp reject_generation_ceiling(%{generation: generation})
       when is_integer(generation) and generation >= 0 do
    :ok
  end

  defp reject_generation_ceiling(_), do: {:error, :invalid_generation}

  defp reject_duplicate_name(%{by_name: by_name}, unit_name) do
    if Map.has_key?(by_name, unit_name) do
      {:error, :duplicate_unit_name}
    else
      :ok
    end
  end

  defp reject_duplicate_execution_id(%{by_name: by_name}, execution_id) do
    if Enum.any?(by_name, fn {_name, record} -> record.execution_id == execution_id end) do
      {:error, :duplicate_execution_id}
    else
      :ok
    end
  end

  defp reject_duplicate_token(%{by_name: by_name}, token) do
    if Enum.any?(by_name, fn {_name, record} -> record.token == token end) do
      {:error, :duplicate_token}
    else
      :ok
    end
  end

  defp fetch_active(%{by_name: by_name}, unit_name) do
    case Map.fetch(by_name, unit_name) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :unknown_unit_name}
    end
  end

  defp match_token(expected, expected), do: :ok
  defp match_token(_expected, _actual), do: {:error, :token_mismatch}

  # --- Projection -------------------------------------------------------------

  defp persist_effect(state), do: [{:persist_snapshot, snapshot(state)}]

  defp snapshot(state) do
    %{
      "schema_version" => state.schema_version,
      "generation" => state.generation,
      "active" => Enum.map(sorted_records(state), &show_record/1)
    }
  end

  defp sorted_records(%{by_name: by_name}) do
    by_name
    |> Map.values()
    |> Enum.sort_by(& &1.unit_name)
  end

  defp show_record(%{
         unit_name: unit_name,
         execution_id: execution_id,
         token: token,
         reserved_at_ms: reserved_at_ms
       }) do
    %{
      "unit_name" => unit_name,
      "execution_id" => execution_id,
      "token" => token,
      "reserved_at_ms" => reserved_at_ms
    }
  end

  # --- Closed-map discipline --------------------------------------------------

  defp validate_closed_keys(map, allowed, logical, scope) when is_map(map) do
    if map_size(map) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(map)

      with :ok <- reject_unknown_keys(keys, allowed, scope),
           :ok <- reject_duplicate_key_aliases(keys, logical, scope) do
        :ok
      end
    end
  end

  defp validate_closed_keys(_, _allowed, _logical, _scope), do: {:error, :invalid_record}

  defp reject_unknown_keys(keys, allowed, scope) do
    if Enum.all?(keys, &MapSet.member?(allowed, &1)) do
      :ok
    else
      {:error, {:unsupported_keys, scope}}
    end
  end

  defp reject_duplicate_key_aliases(keys, logical, scope) do
    key_set = MapSet.new(keys)

    Enum.reduce_while(logical, :ok, fn atom_key, :ok ->
      has_atom? = MapSet.member?(key_set, atom_key)
      has_string? = MapSet.member?(key_set, Atom.to_string(atom_key))

      if has_atom? and has_string? do
        {:halt, {:error, {:duplicate_key_alias, scope, atom_key}}}
      else
        {:cont, :ok}
      end
    end)
  end

  # Distinguishes absent keys from present-but-nil values so callers can
  # return :missing_* vs :invalid_*.
  defp fetch_field(map, key) when is_atom(key) and is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end
    end
  end

  defp has_control_char?(value) when is_binary(value), do: has_control_char_bytes?(value)

  defp has_control_char_bytes?(<<>>), do: false
  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true
  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)

  defp has_whitespace?(value) when is_binary(value) do
    :binary.match(value, [" ", "\t", "\n", "\r", "\f", "\v"]) != :nomatch or
      String.match?(value, ~r/[[:space:]]/)
  end
end
