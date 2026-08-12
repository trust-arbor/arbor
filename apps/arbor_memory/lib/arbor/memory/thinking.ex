defmodule Arbor.Memory.Thinking do
  @moduledoc """
  Store and retrieve Claude thinking blocks.

  Thinking blocks are the internal reasoning traces from Claude's extended
  thinking feature. This module stores them in a ring buffer per agent,
  enabling retrospective analysis of reasoning patterns.

  ## Storage

  Thinking entries are stored in ETS per-agent with a ring buffer
  (default: 50 entries). Each entry includes:
  - The thinking text
  - A timestamp
  - Optional metadata (e.g., which tool call triggered it)
  - Whether it's been flagged as significant for reflection

  ## Stream Processing

  For streaming integration, `process_stream_chunk/3` accumulates
  partial thinking blocks until they're complete, then stores the
  full text.

  Eviction removes an independent item rather than transforming its content.
  The durable aggregate label is therefore recomputed from the exact retained
  item labels. Labels on retained stable IDs never decrease; provenance from a
  removed item is not attached to unrelated retained content.
  """

  use GenServer

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.Memory.MutationAdmission.OwnerRoots
  alias Arbor.Memory.{MemoryStore, Provenance, Signals, ThinkingCodec}

  require Logger

  @ets_table :arbor_memory_thinking
  @default_buffer_size 50
  @max_entries 96
  @max_text_bytes 65_536
  @max_loaded_agents 1_024
  @max_active_streams 1_024
  @max_cas_attempts 8
  @max_projection_attempts 4
  @projection_retry_ms 25
  @owner_call_timeout :infinity

  # ============================================================================
  # Types
  # ============================================================================

  @type thinking_entry :: %{
          id: String.t(),
          agent_id: String.t(),
          text: String.t(),
          significant: boolean(),
          created_at: DateTime.t(),
          metadata: map()
        }

  @type provenance_status ::
          :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type tainted_entry :: {TaintedValue.t(), provenance_status()}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Thinking GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec active_stream_limit() :: pos_integer()
  def active_stream_limit, do: @max_active_streams

  @doc false
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc false
  @spec loaded_agent_limit() :: pos_integer()
  def loaded_agent_limit, do: @max_loaded_agents

  @doc """
  Record a thinking block for an agent.

  ## Options

  - `:significant` — flag as significant for reflection (default: false)
  - `:metadata` — additional metadata map

  ## Examples

      {:ok, entry} = Thinking.record_thinking("agent_001", "Let me analyze the error...",
        significant: true,
        metadata: %{trigger: "test_failure"}
      )
  """
  @spec record_thinking(String.t(), String.t(), keyword()) ::
          {:ok, thinking_entry()} | {:error, atom()}
  def record_thinking(agent_id, text, opts \\ []) do
    record_thinking_tainted(agent_id, text, TaintEnvelope.missing_fallback(), opts)
  end

  @doc "Records thinking with an exact caller-supplied taint label."
  @spec record_thinking_tainted(String.t(), String.t(), Taint.t(), keyword()) ::
          {:ok, thinking_entry()} | {:error, atom()}
  def record_thinking_tainted(agent_id, text, taint, opts \\ [])

  def record_thinking_tainted(agent_id, text, taint, opts)
      when is_binary(agent_id) and is_binary(text) do
    with true <- valid_agent_id?(agent_id),
         :ok <- validate_record_opts(opts),
         {:ok, taint} <- Taint.canonicalize(taint) do
      call_owner({:record, agent_id, text, taint, opts}, :mutation)
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def record_thinking_tainted(_agent_id, _text, _taint, _opts),
    do: {:error, :invalid_request}

  @doc """
  Get recent thinking entries for an agent.

  ## Options

  - `:limit` — max entries to return (default: 10)
  - `:since` — only entries after this DateTime
  - `:significant_only` — only return significant entries (default: false)

  ## Examples

      entries = Thinking.recent_thinking("agent_001", limit: 5)
      significant = Thinking.recent_thinking("agent_001", significant_only: true)
  """
  @spec recent_thinking(String.t(), keyword()) :: [thinking_entry()]
  def recent_thinking(agent_id, opts \\ []) do
    with :ok <- validate_reader_request(agent_id, opts),
         {:ok, entries} <- call_owner({:recent_compat, agent_id, opts}, :read) do
      entries
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "Returns recent thinking with item-specific taint and provenance status."
  @spec recent_thinking_tainted(String.t(), keyword()) ::
          {:ok, [tainted_entry()]} | {:error, atom()}
  def recent_thinking_tainted(agent_id, opts \\ []) do
    case validate_reader_request(agent_id, opts) do
      :ok ->
        call_owner({:recent_tainted, agent_id, opts}, :read)

      _error ->
        {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  @doc """
  Process a streaming thinking chunk.

  Accumulates chunks for an agent until the stream is complete.
  Call with `complete: true` to finalize and store the accumulated text.

  ## Examples

      Thinking.process_stream_chunk("agent_001", "Let me think")
      Thinking.process_stream_chunk("agent_001", " about this...")
      {:ok, entry} = Thinking.process_stream_chunk("agent_001", "", complete: true)
  """
  @spec process_stream_chunk(String.t(), String.t(), keyword()) ::
          :ok | {:ok, thinking_entry()} | {:error, atom()}
  def process_stream_chunk(agent_id, chunk, opts \\ []) do
    process_stream_chunk_tainted(
      agent_id,
      chunk,
      TaintEnvelope.missing_fallback(),
      opts
    )
  end

  @doc "Processes one streaming thinking chunk with an exact taint label."
  @spec process_stream_chunk_tainted(String.t(), String.t(), Taint.t(), keyword()) ::
          :ok | {:ok, thinking_entry()} | {:error, atom()}
  def process_stream_chunk_tainted(agent_id, chunk, taint, opts \\ [])

  def process_stream_chunk_tainted(agent_id, chunk, taint, opts)
      when is_binary(agent_id) and is_binary(chunk) do
    with true <- valid_agent_id?(agent_id),
         :ok <- validate_stream_opts(opts),
         {:ok, taint} <- Taint.canonicalize(taint) do
      call_owner({:stream_chunk, agent_id, chunk, taint, opts}, :mutation)
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def process_stream_chunk_tainted(_agent_id, _chunk, _taint, _opts),
    do: {:error, :invalid_request}

  @doc """
  Clear all thinking entries for an agent.
  """
  @spec clear(String.t()) :: :ok | {:error, atom()}
  def clear(agent_id) do
    if valid_agent_id?(agent_id),
      do: call_owner({:clear, agent_id}, :mutation),
      else: {:error, :invalid_request}
  end

  @doc """
  Idempotent content-only deletion for exactly one agent.

  Removes durable thinking aggregate content, ETS projection, and unfinished
  stream state. Retains every Provenance sidecar byte-for-byte.

  C3I2A precondition (caller-owned, not enforced here): C3I1 mutation gate
  must be closed and drained before invoke. This API is not race-free agent
  destruction.
  """
  @content_delete_errors [
    :invalid_request,
    :store_unavailable,
    :outcome_unknown,
    :conflict,
    :projection_failed
  ]

  @content_absence_errors [:invalid_request, :store_unavailable]

  @spec delete_agent_content(String.t()) ::
          :ok
          | {:error,
             :invalid_request
             | :store_unavailable
             | :outcome_unknown
             | :conflict
             | :projection_failed}
  def delete_agent_content(agent_id) do
    if valid_agent_id?(agent_id) do
      case call_owner({:delete_agent_content, agent_id}, :mutation) do
        :ok -> :ok
        {:error, reason} -> {:error, normalize_content_delete_error(reason)}
        _ -> {:error, :outcome_unknown}
      end
    else
      {:error, :invalid_request}
    end
  end

  @doc """
  Authoritative absence across durable thinking, ETS projection, and unfinished
  stream state. Returns `{:ok, true}` only when no exact-agent content remains.
  """
  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()} | {:error, :invalid_request | :store_unavailable}
  def agent_content_absent?(agent_id) do
    if valid_agent_id?(agent_id) do
      case call_owner({:agent_content_absent?, agent_id}, :read) do
        {:ok, present?} when is_boolean(present?) -> {:ok, present?}
        {:error, reason} -> {:error, normalize_content_absence_error(reason)}
        _ -> {:error, :store_unavailable}
      end
    else
      {:error, :invalid_request}
    end
  end

  @doc "Reloads the complete Thinking projection from the durable memory store."
  @spec reload_from_durable() :: :ok | {:error, atom()}
  def reload_from_durable do
    call_owner(:reload_from_durable, :read)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    ensure_ets_table()
    buffer_size = normalize_buffer_size(Keyword.get(opts, :buffer_size, @default_buffer_size))

    state = %{
      buffer_size: buffer_size,
      streams: %{},
      owned_agents: MapSet.new(),
      owner_roots: OwnerRoots.new(),
      pending_projection: %{}
    }

    {:ok, hydrate_startup(state)}
  end

  @impl true
  def handle_call({:record, agent_id, text, taint, opts}, _from, state) do
    state = normalize_state(state)

    if owned_agent_capacity?(state, agent_id) do
      with_fresh_admission(state, agent_id, {:error, :store_unavailable}, fn state ->
        case store_entry(agent_id, text, taint, opts, state) do
          {:ok, entry, :projected} ->
            {{:ok, entry}, put_owned_agent(state, agent_id), :settle}

          {:ok, entry, :convergence_pending} ->
            {{:ok, entry}, put_owned_agent(state, agent_id), :defer}

          {:error, reason} ->
            {{:error, reason}, state, :ack}
        end
      end)
    else
      {:reply, {:error, :projection_capacity}, state}
    end
  end

  @impl true
  def handle_call({:recent_compat, agent_id, opts}, _from, state) do
    state = normalize_state(state)

    if owned_agent_capacity?(state, agent_id) do
      with_fresh_admission(state, agent_id, {:ok, []}, fn state ->
        case read_authoritative_entries(agent_id, opts, state) do
          {:ok, items, next_state, disposition} ->
            entries = Enum.map(items, fn {value, _status} -> value.value end)
            {{:ok, entries}, next_state, disposition}

          {:error, _reason, next_state, disposition} ->
            {{:ok, []}, next_state, disposition}
        end
      end)
    else
      {:reply, {:ok, []}, state}
    end
  end

  @impl true
  def handle_call({:stream_chunk, agent_id, chunk, taint, opts}, _from, state) do
    state = normalize_state(state)
    complete = Keyword.get(opts, :complete, false)
    current = Map.get(state.streams, agent_id)

    if is_nil(current) and not complete and map_size(state.streams) >= @max_active_streams do
      {:reply, {:error, :stream_capacity}, state}
    else
      case append_stream(current, chunk, taint) do
        {:ok, text, stream_taint} ->
          with_fresh_admission(state, agent_id, {:error, :store_unavailable}, fn state ->
            finish_stream(agent_id, text, stream_taint, opts, state, complete)
          end)

        _error ->
          {:reply, {:error, :invalid_payload}, state}
      end
    end
  end

  @impl true
  def handle_call({:recent_tainted, agent_id, opts}, _from, state) do
    state = normalize_state(state)

    if owned_agent_capacity?(state, agent_id) do
      with_fresh_admission(state, agent_id, {:error, :store_unavailable}, fn state ->
        case read_authoritative_entries(agent_id, opts, state) do
          {:ok, items, next_state, disposition} ->
            {{:ok, items}, next_state, disposition}

          {:error, reason, next_state, disposition} ->
            {{:error, reason}, next_state, disposition}
        end
      end)
    else
      {:reply, {:error, :projection_capacity}, state}
    end
  end

  @impl true
  def handle_call({:clear, agent_id}, _from, state) do
    with_fresh_admission(state, agent_id, {:error, :store_unavailable}, fn state ->
      case delete_aggregate_before_live_clear(agent_id) do
        :ok ->
          next_state =
            state
            |> drop_owned_agent(agent_id)
            |> Map.update!(:streams, &Map.delete(&1, agent_id))

          case clear_live_projection(agent_id) do
            :projected -> {:ok, next_state, :settle}
            :convergence_pending -> {:ok, next_state, :settle_then_defer}
          end

        {:error, reason} ->
          {{:error, normalize_store_error(reason)}, state, :ack}
      end
    end)
  end

  @impl true
  def handle_call({:delete_agent_content, agent_id}, _from, state) do
    state = normalize_state(state)

    disarmed =
      state
      |> clear_pending_projection_only(agent_id)
      |> settle_roots(agent_id, nil)
      |> drop_owned_agent(agent_id)
      |> Map.update!(:streams, &Map.delete(&1, agent_id))

    delete_agent_content_after_disarm(agent_id, disarmed)
  end

  @impl true
  def handle_call({:agent_content_absent?, agent_id}, _from, state) do
    state = normalize_state(state)

    reply =
      case do_agent_content_absent?(agent_id, state) do
        {:ok, present?} when is_boolean(present?) -> {:ok, present?}
        {:error, reason} -> {:error, normalize_content_absence_error(reason)}
        _ -> {:error, :store_unavailable}
      end

    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  @impl true
  def handle_call(:reload_from_durable, _from, state) do
    state = normalize_state(state)

    case load_durable_inventory(state.buffer_size) do
      {:ok, plans} ->
        {next_state, result} = reconcile_reload(state, plans)

        case result do
          :ok -> {:reply, :ok, %{next_state | streams: %{}}}
          {:error, reason} -> {:reply, {:error, reason}, next_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:converge_projection, agent_id}, state) do
    state = normalize_state(state)

    case Map.fetch(pending_projection_map(state), agent_id) do
      :error ->
        {:noreply, state}

      {:ok, attempts} ->
        converge_with_deferred_root(agent_id, attempts, state)
    end
  end

  def handle_info(_message, state), do: {:noreply, normalize_state(state)}

  @impl true
  def format_status(status) when is_map(status) do
    case status do
      %{state: state} when is_map(state) ->
        %{status | state: redact_owner_status(state)}

      _ ->
        status
    end
  end

  def format_status(status), do: status

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, normalize_state(state)}

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp server_name, do: __MODULE__

  defp call_owner(message, kind) when kind in [:read, :mutation] do
    case Process.whereis(server_name()) do
      nil ->
        {:error, :store_unavailable}

      owner when is_pid(owner) ->
        try do
          GenServer.call(owner, message, @owner_call_timeout)
        rescue
          _ -> owner_call_failure(kind)
        catch
          :exit, _ -> owner_call_failure(kind)
          :throw, _ -> owner_call_failure(kind)
        end
    end
  end

  defp owner_call_failure(:mutation), do: {:error, :outcome_unknown}
  defp owner_call_failure(:read), do: {:error, :store_unavailable}

  defp normalize_state(state) when is_map(state) do
    state
    |> Map.put_new(:owner_roots, OwnerRoots.new())
    |> Map.put_new(:pending_projection, %{})
    |> Map.put_new(:streams, %{})
    |> Map.put_new(:owned_agents, MapSet.new())
  end

  defp normalize_state(state), do: state

  defp owner_roots(state) when is_map(state), do: Map.get(state, :owner_roots, OwnerRoots.new())
  defp owner_roots(_state), do: OwnerRoots.new()

  defp put_owner_roots(state, roots) when is_map(state), do: Map.put(state, :owner_roots, roots)

  defp pending_projection_map(%{pending_projection: pending}) when is_map(pending), do: pending
  defp pending_projection_map(_state), do: %{}

  defp admit_fresh(agent_id) do
    case OwnerRoots.admit_new(OwnerRoots.new(), agent_id) do
      {:ok, lease} -> {:ok, lease}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  defp with_fresh_admission(state, agent_id, denied_reply, fun) do
    state = normalize_state(state)

    case admit_fresh(agent_id) do
      {:ok, lease} ->
        try do
          {reply, next_state, disposition} = fun.(state)
          {:reply, reply, finish_public_root(next_state, agent_id, lease, disposition)}
        rescue
          _ ->
            {:reply, denied_reply,
             finish_public_root(normalize_state(state), agent_id, lease, :ack)}
        catch
          _, _ ->
            {:reply, denied_reply,
             finish_public_root(normalize_state(state), agent_id, lease, :ack)}
        end

      {:error, _reason} ->
        {:reply, denied_reply, state}
    end
  end

  defp finish_public_root(state, agent_id, lease, :defer) do
    case OwnerRoots.defer(owner_roots(state), agent_id, lease) do
      {:ok, roots} ->
        state
        |> put_owner_roots(roots)
        |> arm_projection_retry(agent_id)

      {:error, _reason} ->
        ack_root(state, lease)
    end
  end

  defp finish_public_root(state, agent_id, lease, :settle) do
    state
    |> settle_roots(agent_id, lease)
    |> clear_pending_projection_only(agent_id)
  end

  defp finish_public_root(state, agent_id, lease, :settle_then_defer) do
    state
    |> clear_pending_projection_only(agent_id)
    |> settle_roots(agent_id, nil)
    |> defer_fresh_root(agent_id, lease)
  end

  defp finish_public_root(state, _agent_id, lease, _ack) do
    ack_root(state, lease)
  end

  defp defer_fresh_root(state, agent_id, lease) do
    case OwnerRoots.defer(owner_roots(state), agent_id, lease) do
      {:ok, roots} ->
        state
        |> put_owner_roots(roots)
        |> arm_projection_retry(agent_id)

      {:error, _reason} ->
        ack_root(state, lease)
    end
  end

  defp ack_root(state, lease) do
    {roots, _result} = OwnerRoots.ack(owner_roots(state), lease)
    put_owner_roots(state, roots)
  end

  defp settle_roots(state, agent_id, lease \\ nil) do
    {roots, _} = OwnerRoots.settle_agent(owner_roots(state), agent_id, lease)
    put_owner_roots(state, roots)
  end

  defp arm_projection_retry(state, agent_id) do
    pending = pending_projection_map(state)

    if Map.has_key?(pending, agent_id) do
      state
    else
      state = %{state | pending_projection: Map.put(pending, agent_id, 1)}
      Process.send_after(self(), {:converge_projection, agent_id}, @projection_retry_ms)
      state
    end
  end

  defp clear_pending_projection_only(state, agent_id) when is_map(state) do
    pending = pending_projection_map(state)
    Map.put(state, :pending_projection, Map.delete(pending, agent_id))
  end

  defp redact_owner_status(state) when is_map(state) do
    counts =
      case Map.get(state, :owner_roots) do
        %OwnerRoots{by_agent: by_agent} ->
          Map.new(by_agent, fn {agent_id, leases} -> {agent_id, length(leases)} end)

        _ ->
          %{}
      end

    streams =
      state
      |> Map.get(:streams, %{})
      |> Map.new(fn
        {agent_id, %{text: text}} when is_binary(text) ->
          {agent_id, %{bytes: byte_size(text)}}

        {agent_id, _} ->
          {agent_id, %{bytes: 0}}
      end)

    state
    |> Map.put(:owner_roots, counts)
    |> Map.put(:streams, streams)
  end

  defp redact_owner_status(state), do: state

  defp converge_with_deferred_root(agent_id, attempts, state) do
    case OwnerRoots.ensure_deferred_root(owner_roots(state), agent_id) do
      {:error, _reason} ->
        {:noreply, settle_roots(clear_pending_projection_only(state, agent_id), agent_id)}

      {:ok, roots} ->
        admitted = put_owner_roots(state, roots)

        try do
          run_pending_projection_convergence(agent_id, attempts, admitted)
        rescue
          _ ->
            {:noreply, settle_roots(clear_pending_projection_only(admitted, agent_id), agent_id)}
        catch
          _, _ ->
            {:noreply, settle_roots(clear_pending_projection_only(admitted, agent_id), agent_id)}
        end
    end
  end

  defp run_pending_projection_convergence(agent_id, attempts, state) do
    case authoritative_tainted_read(agent_id, [], state.buffer_size) do
      {:ok, _items, present?, :settle} ->
        next =
          if present? do
            put_owned_agent(state, agent_id)
          else
            drop_owned_agent(state, agent_id)
          end

        {:noreply, settle_roots(clear_pending_projection_only(next, agent_id), agent_id)}

      {:error, _reason, _disposition} ->
        retry_or_exhaust_projection(state, agent_id, attempts)
    end
  end

  defp retry_or_exhaust_projection(state, agent_id, attempts) do
    if is_integer(attempts) and attempts < @max_projection_attempts do
      pending = Map.put(pending_projection_map(state), agent_id, attempts + 1)
      state = %{state | pending_projection: pending}
      Process.send_after(self(), {:converge_projection, agent_id}, @projection_retry_ms)
      {:noreply, state}
    else
      {:noreply, settle_roots(clear_pending_projection_only(state, agent_id), agent_id)}
    end
  end

  defp read_authoritative_entries(agent_id, opts, state) do
    case authoritative_tainted_read(agent_id, opts, state.buffer_size) do
      {:ok, items, present?, :settle} ->
        next =
          if present? do
            put_owned_agent(state, agent_id)
          else
            drop_owned_agent(state, agent_id)
          end

        {:ok, items, next, :settle}

      {:error, reason, disposition} ->
        {:error, reason, state, disposition}
    end
  end

  defp owned_agent_capacity?(%{owned_agents: owned_agents}, agent_id) do
    MapSet.member?(owned_agents, agent_id) or MapSet.size(owned_agents) < @max_loaded_agents
  end

  defp put_owned_agent(%{owned_agents: owned_agents} = state, agent_id),
    do: %{state | owned_agents: MapSet.put(owned_agents, agent_id)}

  defp drop_owned_agent(%{owned_agents: owned_agents} = state, agent_id),
    do: %{state | owned_agents: MapSet.delete(owned_agents, agent_id)}

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp build_entry(agent_id, text, opts) do
    %{
      id: generate_id(),
      agent_id: agent_id,
      text: text,
      significant: Keyword.get(opts, :significant, false),
      created_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp generate_id do
    "thk_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end

  # ============================================================================
  # Persistence Helpers
  # ============================================================================

  defp store_entry(agent_id, text, taint, opts, state) do
    entry = build_entry(agent_id, text, opts)

    with true <- owned_agent_capacity?(state, agent_id),
         {:ok, _payload} <- ThinkingCodec.entry_payload(entry) do
      append_authoritative_entry(
        agent_id,
        entry,
        taint,
        state.buffer_size,
        @max_cas_attempts
      )
    else
      false -> {:error, :projection_capacity}
      {:error, reason} -> {:error, normalize_store_error(reason)}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp encode_fitting_aggregate(items), do: encode_fitting_aggregate(items, [])

  defp encode_fitting_aggregate([], _evicted), do: {:error, :invalid_aggregate}

  defp encode_fitting_aggregate(items, evicted) do
    case ThinkingCodec.encode_aggregate(items) do
      {:ok, aggregate, aggregate_taint} ->
        {:ok, aggregate, aggregate_taint, items, Enum.reverse(evicted)}

      {:error, _reason} ->
        case remove_oldest_unprotected(items) do
          {:ok, retained, evicted_entry} ->
            encode_fitting_aggregate(retained, [evicted_entry | evicted])

          :protected_only ->
            {:error, :invalid_aggregate}
        end
    end
  end

  defp remove_oldest_unprotected([_newest]), do: :protected_only

  defp remove_oldest_unprotected(items) do
    case Enum.reverse(items) do
      [oldest | retained_reversed] ->
        {:ok, Enum.reverse(retained_reversed), elem(oldest, 0)}

      _ ->
        :protected_only
    end
  end

  defp append_authoritative_entry(_agent_id, _entry, _taint, _buffer_size, 0),
    do: {:error, :conflict}

  defp append_authoritative_entry(agent_id, entry, taint, buffer_size, attempts) do
    case prepare_authoritative_append(agent_id, entry, taint, buffer_size) do
      {:ok, aggregate, aggregate_taint, labelled_entries, expected_record} ->
        commit_authoritative_append(
          agent_id,
          entry,
          taint,
          buffer_size,
          attempts,
          aggregate,
          aggregate_taint,
          labelled_entries,
          expected_record
        )

      {:error, reason} ->
        {:error, normalize_store_error(reason)}
    end
  end

  defp prepare_authoritative_append(agent_id, entry, taint, buffer_size) do
    with {:ok, durable_items, expected_record} <- load_authoritative_mutation_base(agent_id),
         retained <-
           durable_items
           |> Enum.take(buffer_size)
           |> Enum.map(fn {retained_entry, retained_taint, _status} ->
             {retained_entry, retained_taint}
           end),
         candidates <- Enum.take([{entry, taint} | retained], buffer_size),
         {:ok, aggregate, aggregate_taint, labelled_entries, _evicted} <-
           encode_fitting_aggregate(candidates) do
      {:ok, aggregate, aggregate_taint, labelled_entries, expected_record}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp commit_authoritative_append(
         agent_id,
         entry,
         taint,
         buffer_size,
         attempts,
         aggregate,
         aggregate_taint,
         labelled_entries,
         expected_record
       ) do
    case MemoryStore.compare_and_swap_tainted(
           "thinking",
           agent_id,
           expected_record,
           aggregate,
           taint: aggregate_taint
         ) do
      {:ok, %Record{}} ->
        install_entry_after_commit(agent_id, entry, taint, labelled_entries)

      {:error, {:memory_store, :critical, :conflict}} ->
        append_authoritative_entry(agent_id, entry, taint, buffer_size, attempts - 1)

      {:error, {:memory_store, :invalid_durable_provenance, _reason} = reason} ->
        {:error, normalize_store_error(reason)}

      {:error, {:memory_store, :critical, reason}}
      when reason in [:invalid_request, :invalid_record, :insufficient_durability] ->
        {:error, normalize_store_error({:memory_store, :critical, reason})}

      {:error, _reason} ->
        {:error, :outcome_unknown}

      _other ->
        {:error, :outcome_unknown}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp load_authoritative_mutation_base(agent_id) do
    case MemoryStore.load_tainted_authoritative_with_status("thinking", agent_id) do
      {:ok, %TaintedValue{value: aggregate, taint: outer_taint}, status, %Record{} = record,
       _location} ->
        case ThinkingCodec.decode_aggregate(
               agent_id,
               aggregate,
               outer_taint,
               status,
               @max_entries
             ) do
          {:ok, items} -> {:ok, items, record}
          {:error, _reason} -> {:error, :invalid_payload}
        end

      {:error, :not_found} ->
        {:ok, [], :not_found}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp put_live_label(agent_id, entry_id, payload, taint) do
    case Provenance.put(:thinking_entry, agent_id, entry_id, payload, taint) do
      :ok -> :ok
      _ -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp install_entry_after_commit(agent_id, entry, taint, labelled_entries) do
    entries = Enum.map(labelled_entries, &elem(&1, 0))

    case install_live_entries(agent_id, labelled_entries, entries) do
      :ok ->
        enqueue_embedding(entry, taint)
        emit_recorded(entry)
        {:ok, entry, :projected}

      {:error, _reason} ->
        fail_closed_agent_projection(agent_id)
        {:ok, entry, :convergence_pending}
    end
  rescue
    _ ->
      fail_closed_agent_projection(agent_id)
      {:ok, entry, :convergence_pending}
  catch
    _, _ ->
      fail_closed_agent_projection(agent_id)
      {:ok, entry, :convergence_pending}
  end

  defp install_live_entries(agent_id, labelled_entries, entries) do
    with {:ok, bindings} <- prepare_live_bindings(agent_id, labelled_entries, []),
         true <- :ets.delete(@ets_table, agent_id),
         :ok <- Provenance.delete_domain_agent(:thinking_entry, agent_id),
         :ok <- bind_installation(bindings, []),
         true <- :ets.insert(@ets_table, {agent_id, entries}) do
      :ok
    else
      _ -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp prepare_live_bindings(_agent_id, [], acc), do: {:ok, Enum.reverse(acc)}

  defp prepare_live_bindings(agent_id, [{entry, taint} | rest], acc) do
    with %{agent_id: ^agent_id, id: entry_id} when is_binary(entry_id) <- entry,
         {:ok, payload} <- ThinkingCodec.entry_payload(entry) do
      binding = {agent_id, entry_id, payload, taint}
      prepare_live_bindings(agent_id, rest, [binding | acc])
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp prepare_live_bindings(_agent_id, _entries, _acc), do: {:error, :invalid_payload}

  defp delete_aggregate_before_live_clear(agent_id) do
    if MemoryStore.available?() do
      case MemoryStore.load_tainted_authoritative_with_status("thinking", agent_id) do
        {:ok, %TaintedValue{}, _status, %Record{}, _location} ->
          commit_authoritative_delete(agent_id)

        {:error, :not_found} ->
          commit_authoritative_delete(agent_id)

        {:error, reason} ->
          {:error, normalize_store_error(reason)}

        _other ->
          {:error, :store_unavailable}
      end
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp commit_authoritative_delete(agent_id) do
    case MemoryStore.delete_tainted_authoritative("thinking", agent_id) do
      :ok ->
        :ok

      {:error, {:memory_store, :critical, reason}}
      when reason in [:invalid_request, :invalid_record, :insufficient_durability] ->
        {:error, normalize_store_error({:memory_store, :critical, reason})}

      {:error, _reason} ->
        {:error, :outcome_unknown}

      _other ->
        {:error, :outcome_unknown}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp fail_closed_agent_projection(agent_id) do
    :ets.delete(@ets_table, agent_id)
    _ = Provenance.delete_domain_agent(:thinking_entry, agent_id)
    :ok
  rescue
    _ ->
      :ets.delete(@ets_table, agent_id)
      :ok
  catch
    _, _ ->
      :ets.delete(@ets_table, agent_id)
      :ok
  end

  defp install_empty_projection(agent_id) do
    with true <- :ets.delete(@ets_table, agent_id),
         :ok <- Provenance.delete_domain_agent(:thinking_entry, agent_id) do
      :ok
    else
      _ -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp clear_live_projection(agent_id) do
    case install_empty_projection(agent_id) do
      :ok ->
        :projected

      {:error, _reason} ->
        fail_closed_agent_projection(agent_id)
        :convergence_pending
    end
  rescue
    _ ->
      fail_closed_agent_projection(agent_id)
      :convergence_pending
  catch
    _, _ ->
      fail_closed_agent_projection(agent_id)
      :convergence_pending
  end

  # Content-only eviction with confirmation; never touches Provenance.
  # Only initial :undefined is genuine absence; post-defined races fail closed.
  defp delete_agent_content_after_disarm(agent_id, state) do
    # `state` argument is already ownership-disarmed.
    durable_result = delete_aggregate_before_live_clear(agent_id)

    # Content eviction after durable attempt (even on durable failure).
    next_state = Map.update!(state, :streams, &Map.delete(&1, agent_id))

    projection_result = confirm_evict_thinking_content_only(agent_id)

    reply =
      case {durable_result, projection_result} do
        {:ok, :ok} ->
          :ok

        {{:error, reason}, _} ->
          {:error, normalize_content_delete_error(reason)}

        {:ok, {:error, reason}} ->
          {:error, normalize_content_delete_error(reason)}

        _ ->
          {:error, :outcome_unknown}
      end

    {:reply, reply, next_state}
  rescue
    # Preserve ownership disarm; also drop stream on exceptional path.
    _ ->
      {:reply, {:error, :outcome_unknown},
       Map.update(state, :streams, %{}, &Map.delete(&1, agent_id))}
  catch
    _, _ ->
      {:reply, {:error, :outcome_unknown},
       Map.update(state, :streams, %{}, &Map.delete(&1, agent_id))}
  end

  defp confirm_evict_thinking_content_only(agent_id) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ok

      _tid ->
        true = :ets.delete(@ets_table, agent_id)

        case :ets.lookup(@ets_table, agent_id) do
          [] -> :ok
          _ -> {:error, :projection_failed}
        end
    end
  rescue
    ArgumentError -> {:error, :projection_failed}
  catch
    _, _ -> {:error, :projection_failed}
  end

  defp do_agent_content_absent?(agent_id, state) do
    case durable_thinking_presence(agent_id) do
      :present ->
        {:ok, false}

      :absent ->
        owned? = MapSet.member?(Map.get(state, :owned_agents, MapSet.new()), agent_id)
        stream_absent? = not Map.has_key?(Map.get(state, :streams, %{}), agent_id)
        pending_absent? = not Map.has_key?(pending_projection_map(state), agent_id)
        roots_absent? = not OwnerRoots.held?(owner_roots(state), agent_id)

        case thinking_ets_absent?(agent_id) do
          {:ok, true}
          when not owned? and stream_absent? and pending_absent? and roots_absent? ->
            {:ok, true}

          {:ok, _} ->
            {:ok, false}

          {:error, _reason} ->
            {:error, :store_unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp thinking_ets_absent?(agent_id) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        {:ok, true}

      _tid ->
        case :ets.lookup(@ets_table, agent_id) do
          [] -> {:ok, true}
          _ -> {:ok, false}
        end
    end
  rescue
    ArgumentError -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp durable_thinking_presence(agent_id) do
    if MemoryStore.available?() do
      case MemoryStore.load_tainted_authoritative_with_status("thinking", agent_id) do
        {:ok, %TaintedValue{}, _status, %Record{}, _location} ->
          :present

        {:error, :not_found} ->
          :absent

        {:error, reason} ->
          {:error, normalize_store_error(reason)}

        _other ->
          {:error, :store_unavailable}
      end
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp append_stream(nil, chunk, taint) do
    with :ok <- validate_stream_text(chunk),
         {:ok, taint} <- Taint.canonicalize(taint) do
      {:ok, chunk, taint}
    end
  end

  defp append_stream(%{text: accumulated, taint: accumulated_taint}, chunk, taint)
       when is_binary(accumulated) do
    accumulated_bytes = byte_size(accumulated)

    with :ok <- validate_stream_text(accumulated),
         :ok <- validate_stream_text(chunk),
         true <- byte_size(chunk) <= @max_text_bytes - accumulated_bytes,
         {:ok, joined} <- Taint.join(accumulated_taint, taint) do
      {:ok, accumulated <> chunk, joined}
    end
  end

  defp append_stream(_current, _chunk, _taint), do: {:error, :invalid_payload}

  defp validate_stream_text(text)
       when is_binary(text) and byte_size(text) <= @max_text_bytes,
       do: if(String.valid?(text), do: :ok, else: {:error, :invalid_payload})

  defp validate_stream_text(_text), do: {:error, :invalid_payload}

  defp finish_stream(agent_id, text, stream_taint, opts, state, complete) do
    if not complete do
      streams = Map.put(state.streams, agent_id, %{text: text, taint: stream_taint})
      {:ok, %{state | streams: streams}, :ack}
    else
      finish_completed_stream(agent_id, text, stream_taint, opts, state)
    end
  end

  defp finish_completed_stream(agent_id, text, stream_taint, opts, state) do
    if String.trim(text) == "" do
      {:ok, %{state | streams: Map.delete(state.streams, agent_id)}, :ack}
    else
      case store_entry(agent_id, text, stream_taint, opts, state) do
        {:ok, entry, :projected} ->
          next_state =
            state
            |> put_owned_agent(agent_id)
            |> Map.update!(:streams, &Map.delete(&1, agent_id))

          {{:ok, entry}, next_state, :settle}

        {:ok, entry, :convergence_pending} ->
          next_state =
            state
            |> put_owned_agent(agent_id)
            |> Map.update!(:streams, &Map.delete(&1, agent_id))

          {{:ok, entry}, next_state, :defer}

        {:error, reason} ->
          {{:error, reason}, state, :ack}
      end
    end
  end

  defp authoritative_tainted_read(agent_id, opts, buffer_size) do
    case load_authoritative_mutation_base(agent_id) do
      {:ok, durable_items, _expected_record} ->
        reconcile_durable_read(agent_id, durable_items, opts, buffer_size)

      {:error, reason} ->
        {:error, normalize_store_error(reason), :ack}
    end
  rescue
    _ -> {:error, :store_unavailable, :ack}
  catch
    _, _ -> {:error, :store_unavailable, :ack}
  end

  defp reconcile_durable_read(agent_id, durable_items, opts, buffer_size) do
    case reconcile_authoritative_projection(agent_id, durable_items, buffer_size) do
      {:ok, projection} ->
        {:ok, filter_decoded_items(projection, opts), projection != [], :settle}

      {:error, reason} ->
        {:error, reason, :defer}
    end
  end

  defp reconcile_authoritative_projection(agent_id, durable_items, buffer_size) do
    projection = Enum.take(durable_items, buffer_size)
    labelled_entries = Enum.map(projection, fn {entry, taint, _status} -> {entry, taint} end)
    entries = Enum.map(projection, &elem(&1, 0))

    install_result =
      case labelled_entries do
        [] ->
          install_empty_projection(agent_id)

        _ ->
          install_live_entries(agent_id, labelled_entries, entries)
      end

    case install_result do
      :ok ->
        {:ok, projection}

      {:error, _reason} ->
        fail_closed_agent_projection(agent_id)
        {:error, :store_unavailable}
    end
  rescue
    _ ->
      fail_closed_agent_projection(agent_id)
      {:error, :store_unavailable}
  catch
    _, _ ->
      fail_closed_agent_projection(agent_id)
      {:error, :store_unavailable}
  end

  defp filter_decoded_items(items, opts) do
    since = Keyword.get(opts, :since)
    significant_only = Keyword.get(opts, :significant_only, false)
    limit = Keyword.get(opts, :limit, 10)

    items
    |> Enum.filter(fn {entry, _taint, _status} ->
      (not significant_only or entry.significant) and entry_since?(entry, since)
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {entry, taint, status} ->
      {TaintedValue.wrap(entry, taint), ThinkingCodec.status_for(taint, status)}
    end)
  end

  defp entry_since?(_entry, nil), do: true

  defp entry_since?(%{created_at: %DateTime{} = created_at}, %DateTime{} = since),
    do: DateTime.compare(created_at, since) in [:gt, :eq]

  defp entry_since?(_entry, _since), do: false

  defp hydrate_startup(state) do
    case load_durable_inventory(state.buffer_size) do
      {:ok, plans} ->
        next =
          Enum.reduce(plans, state, fn plan, acc ->
            reconcile_startup_agent(acc, plan)
          end)

        Logger.info("Thinking durable projection loaded", record_count: length(plans))
        next

      {:error, _reason} ->
        state
    end
  end

  defp load_durable_inventory(buffer_size) do
    with {:ok, records} <- MemoryStore.load_all_tainted_authoritative("thinking"),
         {:ok, plans} <- decode_records(records, buffer_size, 0, []) do
      {:ok, plans}
    else
      {:error, reason} -> {:error, normalize_store_error(reason)}
      _ -> {:error, :invalid_durable_state}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp reconcile_startup_agent(state, {agent_id, items}) do
    if valid_agent_id?(agent_id) do
      case admit_and_reconcile_agent(state, agent_id, items) do
        {_result, next_state} -> next_state
      end
    else
      state
    end
  end

  defp reconcile_startup_agent(state, _plan), do: state

  defp reconcile_reload(state, plans) do
    plan_map =
      Enum.reduce(plans, %{}, fn
        {agent_id, items}, acc when is_binary(agent_id) ->
          if valid_agent_id?(agent_id) and not Map.has_key?(acc, agent_id) do
            Map.put(acc, agent_id, items)
          else
            acc
          end

        _plan, acc ->
          acc
      end)

    durable_ids = MapSet.new(Map.keys(plan_map))
    previously_owned = Map.get(state, :owned_agents, MapSet.new())
    absence_ids = MapSet.difference(previously_owned, durable_ids)

    {state, durable_ok?} =
      Enum.reduce(plan_map, {state, true}, fn {agent_id, items}, {acc, ok?} ->
        reduce_reload_agent(acc, ok?, agent_id, items)
      end)

    {state, absence_ok?} =
      Enum.reduce(MapSet.to_list(absence_ids), {state, true}, fn agent_id, {acc, ok?} ->
        reduce_reload_agent(acc, ok?, agent_id, [])
      end)

    if durable_ok? and absence_ok? do
      {state, :ok}
    else
      {state, {:error, :store_unavailable}}
    end
  end

  defp reduce_reload_agent(state, ok?, agent_id, items) do
    case admit_and_reconcile_agent(state, agent_id, items) do
      {:ok, next} ->
        {Map.update(next, :streams, %{}, &Map.delete(&1, agent_id)), ok?}

      {:skipped, next} ->
        {next, false}

      {:error, next} ->
        {next, false}
    end
  end

  defp admit_and_reconcile_agent(state, agent_id, items) do
    case admit_fresh(agent_id) do
      {:error, _reason} ->
        {:skipped, state}

      {:ok, lease} ->
        apply_reconcile_one(state, agent_id, items, lease)
    end
  end

  defp apply_reconcile_one(state, agent_id, items, lease) do
    try do
      case install_reconciled_projection(agent_id, items, state.buffer_size) do
        {:ok, :present} ->
          {:ok, finish_public_root(put_owned_agent(state, agent_id), agent_id, lease, :settle)}

        {:ok, :absent} ->
          {:ok, finish_public_root(drop_owned_agent(state, agent_id), agent_id, lease, :settle)}

        {:error, :convergence_pending} ->
          {:error, finish_public_root(state, agent_id, lease, :defer)}
      end
    rescue
      _ ->
        {:error, finish_public_root(normalize_state(state), agent_id, lease, :ack)}
    catch
      _, _ ->
        {:error, finish_public_root(normalize_state(state), agent_id, lease, :ack)}
    end
  end

  defp install_reconciled_projection(agent_id, items, buffer_size) do
    projection = Enum.take(items, buffer_size)
    labelled_entries = Enum.map(projection, fn {entry, taint, _status} -> {entry, taint} end)
    entries = Enum.map(projection, &elem(&1, 0))

    install_result =
      case labelled_entries do
        [] -> install_empty_projection(agent_id)
        _ -> install_live_entries(agent_id, labelled_entries, entries)
      end

    case install_result do
      :ok when labelled_entries == [] ->
        {:ok, :absent}

      :ok ->
        {:ok, :present}

      {:error, _reason} ->
        fail_closed_agent_projection(agent_id)
        {:error, :convergence_pending}
    end
  rescue
    _ ->
      fail_closed_agent_projection(agent_id)
      {:error, :convergence_pending}
  catch
    _, _ ->
      fail_closed_agent_projection(agent_id)
      {:error, :convergence_pending}
  end

  defp decode_records([], _buffer_size, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_records([record | rest], buffer_size, count, acc)
       when count < @max_loaded_agents do
    plan = decode_record(record, buffer_size)
    decode_records(rest, buffer_size, count + 1, [plan | acc])
  end

  defp decode_records(_records, _buffer_size, _count, _acc),
    do: {:error, :invalid_durable_state}

  defp decode_record(
         {agent_id, %TaintedValue{value: aggregate, taint: outer_taint}, status},
         limit
       ) do
    case ThinkingCodec.decode_aggregate(agent_id, aggregate, outer_taint, status, limit) do
      {:ok, items} -> {agent_id, items}
      {:error, _reason} -> {agent_id, []}
    end
  end

  defp decode_record(_record, _limit), do: {nil, []}

  defp bind_installation([], _bound), do: :ok

  defp bind_installation([{agent_id, entry_id, payload, taint} = binding | rest], bound) do
    case put_live_label(agent_id, entry_id, payload, taint) do
      :ok ->
        bind_installation(rest, [binding | bound])

      {:error, _reason} ->
        cleanup_bindings(bound)
        {:error, :store_unavailable}
    end
  end

  defp bind_installation(_bindings, bound) do
    cleanup_bindings(bound)
    {:error, :invalid_durable_state}
  end

  defp cleanup_bindings(bindings) do
    Enum.each(bindings, fn {agent_id, entry_id, _payload, _taint} ->
      _ = Provenance.delete(:thinking_entry, agent_id, entry_id)
    end)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # C3G owns shared embedding identity, provenance convergence, and eviction.
  # Thinking only preserves the existing post-commit enqueue path and never
  # deletes content-hash embeddings that another memory domain may share.
  defp enqueue_embedding(entry, taint) do
    _ =
      MemoryStore.embed_async("thinking", "#{entry.agent_id}:#{entry.id}", entry.text,
        agent_id: entry.agent_id,
        type: :thought,
        taint: taint
      )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp emit_recorded(entry) do
    Signals.emit_memory_signal(entry.agent_id, :thinking_recorded, %{
      entry_id: entry.id,
      text_bytes: byte_size(entry.text),
      significant: entry.significant,
      recorded_at: entry.created_at
    })

    Logger.debug("Thinking recorded", agent_id: entry.agent_id, entry_id: entry.id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp validate_record_opts(opts) do
    with :ok <- validate_keyword_keys(opts, [:significant, :metadata]),
         significant <- Keyword.get(opts, :significant, false),
         metadata <- Keyword.get(opts, :metadata, %{}),
         true <- is_boolean(significant),
         true <- is_map(metadata) and not is_struct(metadata) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_stream_opts(opts) do
    with :ok <- validate_keyword_keys(opts, [:complete, :significant, :metadata]),
         true <- is_boolean(Keyword.get(opts, :complete, false)) do
      validate_record_opts(Keyword.delete(opts, :complete))
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_reader_request(agent_id, opts) do
    with true <- valid_agent_id?(agent_id),
         :ok <- validate_keyword_keys(opts, [:limit, :since, :significant_only]),
         limit <- Keyword.get(opts, :limit, 10),
         true <- is_integer(limit) and limit >= 0 and limit <= @max_entries,
         since <- Keyword.get(opts, :since),
         true <- is_nil(since) or match?(%DateTime{}, since),
         true <- is_boolean(Keyword.get(opts, :significant_only, false)) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_keyword_keys(opts, allowed) do
    with {:ok, keys} <- bounded_keyword_keys(opts, length(allowed), [], 0),
         true <- Enum.all?(keys, &(&1 in allowed)),
         true <- length(keys) == MapSet.size(MapSet.new(keys)) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp bounded_keyword_keys([], _max, acc, _count), do: {:ok, Enum.reverse(acc)}

  defp bounded_keyword_keys([{key, _value} | rest], max, acc, count)
       when is_atom(key) and count < max,
       do: bounded_keyword_keys(rest, max, [key | acc], count + 1)

  defp bounded_keyword_keys(_opts, _max, _acc, _count),
    do: {:error, :invalid_request}

  defp valid_agent_id?(agent_id) when is_binary(agent_id) do
    byte_size(agent_id) in 1..256 and String.valid?(agent_id) and String.trim(agent_id) != ""
  end

  defp valid_agent_id?(_agent_id), do: false

  defp normalize_buffer_size(size)
       when is_integer(size) and size > 0 and size <= @max_entries,
       do: size

  defp normalize_buffer_size(_size), do: @default_buffer_size

  defp normalize_store_error(reason)
       when reason in [:invalid_payload, :invalid_aggregate, :invalid_request],
       do: :invalid_payload

  defp normalize_store_error({:memory_store, :invalid_durable_provenance, _reason}),
    do: :invalid_payload

  defp normalize_store_error({:memory_store, :critical, :outcome_unknown}),
    do: :outcome_unknown

  defp normalize_store_error({:memory_store, :critical, :conflict}), do: :conflict
  defp normalize_store_error(:outcome_unknown), do: :outcome_unknown
  defp normalize_store_error(:conflict), do: :conflict
  defp normalize_store_error(:projection_failed), do: :projection_failed
  defp normalize_store_error(:projection_capacity), do: :projection_capacity
  defp normalize_store_error({:memory_store, :critical, :invalid_record}), do: :store_unavailable
  defp normalize_store_error(_reason), do: :store_unavailable

  # Cleanup-only: map every backend/store shape into the declared closed unions.
  defp normalize_content_delete_error(reason) when reason in @content_delete_errors, do: reason

  defp normalize_content_delete_error(reason) do
    case normalize_store_error(reason) do
      allowed when allowed in @content_delete_errors -> allowed
      :invalid_payload -> :store_unavailable
      :projection_capacity -> :store_unavailable
      _ -> :outcome_unknown
    end
  end

  defp normalize_content_absence_error(reason) when reason in @content_absence_errors, do: reason

  defp normalize_content_absence_error(reason) do
    case normalize_store_error(reason) do
      allowed when allowed in @content_absence_errors -> allowed
      _ -> :store_unavailable
    end
  end

  # ============================================================================
  # Multi-Provider Extraction (ported from Seed ThinkingBlockProcessor)
  # ============================================================================

  @doc """
  Extract thinking content from an LLM response.

  Supports multiple providers:
  - `:anthropic` — content blocks with `"type" => "thinking"`
  - `:deepseek` — `reasoning_content` field
  - `:openai` — explicitly returns `{:none, :hidden_reasoning}` (o1/o3 hide reasoning)
  - `:generic` — fallback chain: anthropic → deepseek → XML `<thinking>` tags

  ## Options

  - `:fallback_to_generic` — try generic extraction on failure (default: false)

  ## Returns

  - `{:ok, text}` — extracted thinking text
  - `{:none, reason}` — no thinking found
  """
  @spec extract(map(), atom(), keyword()) :: {:ok, String.t()} | {:none, atom()}
  def extract(response, provider, opts \\ [])

  def extract(response, :anthropic, opts) do
    case extract_anthropic_thinking(response) do
      {:ok, _} = ok ->
        ok

      {:none, _} = none ->
        if Keyword.get(opts, :fallback_to_generic, false),
          do: extract(response, :generic, []),
          else: none
    end
  end

  def extract(response, :deepseek, opts) do
    case extract_deepseek_reasoning(response) do
      {:ok, _} = ok ->
        ok

      {:none, _} = none ->
        if Keyword.get(opts, :fallback_to_generic, false),
          do: extract(response, :generic, []),
          else: none
    end
  end

  def extract(_response, :openai, _opts) do
    {:none, :hidden_reasoning}
  end

  def extract(response, :generic, _opts) do
    extract_generic_thinking(response)
  end

  def extract(response, _unknown_provider, _opts) do
    extract_generic_thinking(response)
  end

  @doc """
  Extract thinking from an LLM response and record it for the agent.

  Combines `extract/3` and `record_thinking/3`. Automatically flags
  identity-affecting thinking as significant.
  """
  @spec extract_and_record(String.t(), map(), atom(), keyword()) ::
          {:ok, thinking_entry()} | {:none, atom()} | {:error, atom()}
  def extract_and_record(agent_id, response, provider, opts \\ []) do
    case extract(response, provider, opts) do
      {:ok, text} ->
        significant = identity_affecting?(text)
        metadata = Keyword.get(opts, :metadata, %{})
        record_thinking(agent_id, text, significant: significant, metadata: metadata)

      {:none, reason} ->
        {:none, reason}
    end
  end

  @doc """
  Returns true if the thinking text contains identity-affecting patterns.

  Checks for goal-related, learning, self-reflection, and constraint keywords.
  """
  @spec identity_affecting?(String.t()) :: boolean()
  def identity_affecting?(text) when is_binary(text) do
    downcased = String.downcase(text)

    goal_patterns = ["my goal", "i should", "i want to", "i need to"]
    learning_patterns = ["i learned", "i realize", "i understand now", "i discovered"]
    self_patterns = ["i am", "my purpose", "my role", "my values"]
    constraint_patterns = ["i cannot", "i must not", "my constraints"]

    Enum.any?(
      goal_patterns ++ learning_patterns ++ self_patterns ++ constraint_patterns,
      fn pattern ->
        String.contains?(downcased, pattern)
      end
    )
  end

  def identity_affecting?(_), do: false

  # ============================================================================
  # Provider-Specific Extraction
  # ============================================================================

  defp extract_anthropic_thinking(response) do
    blocks = get_content_blocks(response)

    thinking_texts =
      blocks
      |> Enum.filter(&(is_map(&1) and (&1["type"] == "thinking" or &1[:type] == "thinking")))
      |> Enum.map(&(&1["thinking"] || &1[:thinking] || ""))
      |> Enum.reject(&(&1 == ""))

    case thinking_texts do
      [] -> {:none, :no_thinking_blocks}
      texts -> {:ok, Enum.join(texts, "\n\n")}
    end
  end

  defp extract_deepseek_reasoning(response) do
    reasoning =
      get_nested(response, ["reasoning_content"]) ||
        get_nested(response, [:reasoning_content])

    case reasoning do
      nil -> {:none, :no_reasoning_content}
      "" -> {:none, :no_reasoning_content}
      text when is_binary(text) -> {:ok, text}
      _ -> {:none, :no_reasoning_content}
    end
  end

  defp extract_generic_thinking(response) do
    with :not_found <- try_anthropic_thinking(response),
         :not_found <- try_deepseek_reasoning(response),
         :not_found <- try_thinking_field(response) do
      extract_xml_thinking(response)
    end
  end

  defp try_anthropic_thinking(response) do
    case extract_anthropic_thinking(response) do
      {:ok, _} = ok -> ok
      _ -> :not_found
    end
  end

  defp try_deepseek_reasoning(response) do
    case extract_deepseek_reasoning(response) do
      {:ok, _} = ok -> ok
      _ -> :not_found
    end
  end

  defp try_thinking_field(response) do
    thinking = get_nested(response, ["thinking"]) || get_nested(response, [:thinking])

    case thinking do
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> :not_found
    end
  end

  defp extract_xml_thinking(response) do
    text = extract_text_content(response)

    case Regex.run(~r/<thinking>(.*?)<\/thinking>/s, text) do
      [_, captured] when captured != "" -> {:ok, String.trim(captured)}
      _ -> {:none, :no_thinking_found}
    end
  end

  defp extract_text_content(response) when is_binary(response), do: response

  defp extract_text_content(response) when is_map(response) do
    cond do
      is_binary(response["content"]) -> response["content"]
      is_binary(response[:content]) -> response[:content]
      true -> extract_text_from_blocks(response)
    end
  end

  defp extract_text_content(_response), do: ""

  defp extract_text_from_blocks(response) do
    response
    |> get_content_blocks()
    |> Enum.filter(&(is_map(&1) and (&1["type"] == "text" or &1[:type] == "text")))
    |> Enum.map_join("\n", &(&1["text"] || &1[:text] || ""))
  end

  defp get_content_blocks(response) when is_map(response) do
    cond do
      is_list(response["content"]) -> response["content"]
      is_list(response[:content]) -> response[:content]
      true -> []
    end
  end

  defp get_content_blocks(_), do: []

  defp get_nested(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:halt, value}
        _ -> {:halt, nil}
      end
    end)
  end

  defp get_nested(_, _), do: nil
end
