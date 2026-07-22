defmodule Arbor.AI.AcpManaged.SessionRegistry do
  @moduledoc """
  AI-owned managed ACP session registry.

  Mints opaque durable handles (`acp_worker_*`) for live `AcpSession` processes
  (pooled or non-pooled). Registry entries keep PIDs, monitor refs, and
  ownership private; public views are JSON-clean.

  ## Ownership and authority

  * The owner PID is always the live GenServer caller at register time.
    Caller-supplied owner options are never authority.
  * Same live owner may resolve/status/send/close.
  * Cross-process access requires BOTH the same non-empty `task_id` and
    `principal_id`. Handle alone and `task_id` alone are not authority.
  * Owner death immediately closes a non-pooled session or checks a pooled
    session back in when `return_to_pool` applies.
  * Session death removes the handle.
  * Close is idempotent; stale handles fail predictably (`:not_found` on
    resolve/status/send, success-with-already-closed on close).
  """

  use GenServer

  require Logger

  alias Arbor.AI.OwnedOperation

  @type public_view :: %{
          worker_session_id: String.t(),
          session_id: String.t() | nil,
          provider: String.t(),
          model: String.t() | nil,
          status: String.t(),
          pooled: boolean()
        }

  @type entry :: %{
          worker_session_id: String.t(),
          session_pid: pid(),
          session_ref: reference(),
          session_module: module(),
          pool_module: module() | nil,
          owner_pid: pid(),
          owner_ref: reference(),
          provider: atom() | String.t(),
          model: String.t() | nil,
          session_id: String.t() | nil,
          status: String.t(),
          pooled: boolean(),
          return_to_pool: boolean(),
          task_id: String.t() | nil,
          principal_id: String.t() | nil
        }

  @registry_name __MODULE__
  @handle_prefix "acp_worker_"
  @cleanup_timeout_ms 5_000
  @max_inventory_records 10_000
  @max_inventory_id_bytes 256

  # -- Public API -----------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Register a live session under an opaque managed handle.

  Owner is always the GenServer caller. Monitors owner and session before
  publishing the handle. Returns a JSON-clean public view.
  """
  @spec register(map(), keyword()) :: {:ok, public_view()} | {:error, term()}
  def register(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, opts, _remaining} <- normalized_call_opts(opts),
         {:ok, deadline} <- Arbor.AI.Timeout.deadline(opts) do
      call({:register, normalize_register_attrs(attrs), deadline}, opts)
    end
  end

  @doc """
  Resolve a managed handle for an authorized caller.

  Returns an internal resolve map (includes `session_pid` / `session_module`)
  for the facade to invoke the session **from the original caller process**.
  Not a public Engine-facing result - never put the resolve map in context.
  """
  @spec resolve(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def resolve(worker_session_id, opts \\ []) when is_binary(worker_session_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:resolve, worker_session_id, caller}, server_opts)
  end

  @doc false
  @spec resolve_task_control(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_task_control(task_id, principal_id, opts \\ [])
      when is_binary(task_id) and is_binary(principal_id) and is_list(opts) do
    timeout_keys = Arbor.LLM.timeout_option_keys()

    call(
      {:resolve_task_control, normalize_id(task_id), normalize_id(principal_id)},
      Enum.filter(opts, fn
        {key, _value} when is_atom(key) ->
          key == :server or key == :deadline_ms or key in timeout_keys

        _invalid ->
          true
      end)
    )
  end

  @doc """
  Return JSON-clean status metadata when authorized.
  """
  @spec status(String.t(), keyword() | map()) :: {:ok, public_view()} | {:error, term()}
  def status(worker_session_id, opts \\ []) when is_binary(worker_session_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:status, worker_session_id, caller}, server_opts)
  end

  @doc false
  @spec inventory(map(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def inventory(filters, max_items, opts \\ [])
      when is_map(filters) and is_integer(max_items) and max_items > 0 and is_list(opts) do
    with {:ok, opts, _remaining} <- normalized_call_opts(opts) do
      call({:inventory, filters, max_items}, opts)
    end
  end

  @doc false
  @spec inventory_projection(map(), map(), pos_integer(), map()) :: map()
  def inventory_projection(state, filters, max_items, liveness \\ %{})

  def inventory_projection(state, filters, max_items, liveness)
      when is_map(state) and is_map(filters) and is_integer(max_items) and max_items > 0 and
             is_map(liveness) do
    {records, observed_count, hard_truncated} = bounded_inventory_records(state)

    {candidates, malformed_count} =
      Enum.reduce(records, {[], 0}, fn record, {candidates, malformed} ->
        case project_inventory_record(record, liveness) do
          {:ok, session, record_identities} ->
            {[{:valid, record, session, record_identities} | candidates], malformed}

          :malformed ->
            {[{:malformed, record} | candidates], malformed + 1}
        end
      end)

    candidates = Enum.reverse(candidates)

    identity_counts =
      Enum.reduce(candidates, %{}, fn
        {:valid, _record, _session, record_identities}, counts ->
          Enum.reduce(record_identities, counts, fn identity, counts ->
            Map.update(counts, identity, 1, &(&1 + 1))
          end)

        {:malformed, _record}, counts ->
          counts
      end)

    {sessions, quarantine, duplicate_count} =
      Enum.reduce(candidates, {[], [], 0}, fn
        {:malformed, record}, {sessions, quarantine, duplicates} ->
          {sessions, [quarantine_entry(record, "malformed") | quarantine], duplicates}

        {:valid, record, session, record_identities}, {sessions, quarantine, duplicates} ->
          duplicate? = Enum.any?(record_identities, &(Map.get(identity_counts, &1, 0) > 1))

          if duplicate? do
            {sessions, [quarantine_entry(record, "duplicate_identity") | quarantine],
             duplicates + 1}
          else
            {[{session, record_identities} | sessions], quarantine, duplicates}
          end
      end)

    sessions = Enum.reverse(sessions)
    quarantine = Enum.reverse(quarantine)

    matching_sessions =
      sessions
      |> Enum.map(fn {session, _identities} -> session end)
      |> Enum.filter(&inventory_matches?(&1, filters))
      |> Enum.sort_by(&inventory_sort_key/1)

    returned_sessions = Enum.take(matching_sessions, max_items)
    matching_count = length(matching_sessions)
    returned_count = length(returned_sessions)
    quarantined_count = malformed_count + duplicate_count
    filtered_out = max(observed_count - quarantined_count - matching_count, 0)
    truncated_count = max(matching_count - returned_count, 0)
    returned_quarantine = Enum.take(quarantine, max_items)

    %{
      "schema_version" => 1,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{
        "task_id" => Map.get(filters, :task_id),
        "principal_id" => Map.get(filters, :principal_id)
      },
      "max_items" => max_items,
      "truncated" => hard_truncated or truncated_count > 0 or length(quarantine) > max_items,
      "counts" => %{
        "observed" => observed_count,
        "matching" => matching_count,
        "returned" => returned_count,
        "filtered_out" => filtered_out,
        "truncated" => truncated_count,
        "malformed" => malformed_count,
        "duplicates" => duplicate_count,
        "quarantined" => quarantined_count,
        "quarantine_returned" => length(returned_quarantine),
        "quarantine_truncated" => max(length(quarantine) - length(returned_quarantine), 0)
      },
      "sessions" => returned_sessions,
      "quarantine" => returned_quarantine
    }
  end

  def inventory_projection(_state, _filters, _max_items, _liveness), do: invalid_inventory()

  @doc """
  Close or check in a managed session when authorized.

  Idempotent: unknown/already-closed handles return success with
  `status: "already_closed"`.

  An explicit `return_to_pool: true|false` option overrides the stored pooled
  close policy for this close only. Owner-death cleanup still uses the stored
  default from registration.
  """
  @spec close(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def close(worker_session_id, opts \\ []) when is_binary(worker_session_id) do
    {server_opts, caller} = split_caller_opts(opts)
    return_to_pool_override = return_to_pool_override(opts)

    with {:ok, server_opts, _remaining} <- normalized_call_opts(server_opts),
         {:ok, deadline} <- Arbor.AI.Timeout.deadline(server_opts) do
      close_until(
        worker_session_id,
        caller,
        return_to_pool_override,
        server_opts,
        deadline
      )
    end
  end

  @doc false
  @spec public_view(map()) :: public_view()
  def public_view(entry) when is_map(entry) do
    %{
      worker_session_id: entry.worker_session_id,
      session_id: entry.session_id,
      provider: provider_string(entry.provider),
      model: entry.model,
      status: status_string(entry.status),
      pooled: entry.pooled == true
    }
  end

  @doc false
  def handle_prefix, do: @handle_prefix

  # -- GenServer ------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}, by_ref: %{}, closures: %{}}}
  end

  @impl true
  def handle_call({:inventory, filters, max_items}, _from, state)
      when is_map(filters) and is_integer(max_items) do
    inventory = inventory_projection(state, filters, max_items, inventory_liveness(state))
    {:reply, {:ok, inventory}, state}
  rescue
    _ -> {:reply, {:error, :session_inventory_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :session_inventory_unavailable}, state}
  end

  # Inventory messages are data-only. A selector-bearing legacy or forged
  # message is rejected without inspecting or executing the supplied term.
  def handle_call({:inventory, _filters, _max_items, _selector}, _from, state),
    do: {:reply, {:error, :invalid_session_inventory_message}, state}

  def handle_call({:inventory, _filters, _max_items}, _from, state),
    do: {:reply, {:error, :invalid_session_inventory_options}, state}

  @impl true
  def handle_call({:register, attrs, deadline}, {owner_pid, _tag}, state) do
    if deadline_active?(deadline) do
      case do_register(attrs, owner_pid, state) do
        {:ok, view, registered_state} ->
          if deadline_active?(deadline) do
            {:reply, {:ok, view}, registered_state}
          else
            {:reply, {:error, :timeout},
             discard_registration(registered_state, view.worker_session_id)}
          end

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :timeout}, state}
    end
  end

  def handle_call({:resolve, worker_session_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    case fetch_authorized(state, worker_session_id, caller) do
      {:ok, entry} ->
        {:reply, {:ok, resolve_view(entry)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Task control has no worker handle authority. It must find exactly one live
  # task/principal pair; duplicate registrations are an explicit ambiguity.
  def handle_call({:resolve_task_control, task_id, principal_id}, _from, state) do
    matches =
      state.sessions
      |> Map.values()
      |> Enum.filter(fn entry ->
        entry.task_id == task_id and entry.principal_id == principal_id and
          non_empty_id?(task_id) and non_empty_id?(principal_id) and
          Process.alive?(entry.session_pid)
      end)

    case matches do
      [entry] -> {:reply, {:ok, resolve_view(entry)}, state}
      [] -> {:reply, {:error, :not_found}, state}
      _ -> {:reply, {:error, :ambiguous_task_control_session}, state}
    end
  end

  def handle_call({:status, worker_session_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    case fetch_authorized(state, worker_session_id, caller) do
      {:ok, entry} ->
        {:reply, {:ok, public_view(entry)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:close, worker_session_id, request},
        {from_pid, _tag},
        state
      ) do
    if deadline_active?(request.deadline_ms) do
      caller = %{request.caller | owner_pid: from_pid}
      handle_close_request(state, worker_session_id, caller, request)
    else
      {:reply, {:error, :timeout}, state}
    end
  end

  def handle_info(
        {:close_cleanup_complete, worker_session_id, operation_ref, result},
        state
      ) do
    case Map.get(state.closures, worker_session_id) do
      %{operation_ref: ^operation_ref} = closure ->
        state = finish_closure(state, closure)

        safe_send_alias(closure.reply_alias, {operation_ref, :close_cleanup, result})

        {:noreply, state}

      _missing_or_stale ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.by_ref, ref) do
      {nil, _by_ref} ->
        {:noreply, state}

      {{:owner, worker_session_id}, by_ref} ->
        state = %{state | by_ref: by_ref}
        state = handle_owner_down(state, worker_session_id, pid, reason)
        {:noreply, state}

      {{:session, worker_session_id}, by_ref} ->
        state = %{state | by_ref: by_ref}
        state = handle_session_down(state, worker_session_id, pid, reason)
        {:noreply, state}

      {{:close_cleanup, worker_session_id, operation_ref}, by_ref} ->
        state = %{state | by_ref: by_ref}
        state = handle_cleanup_down(state, worker_session_id, operation_ref, ref, reason)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------

  defp bounded_inventory_records(state) do
    {sessions, session_count, sessions_truncated} =
      inventory_source_records(Map.get(state, :sessions), :registered)

    {closures, closure_count, closures_truncated} =
      inventory_source_records(Map.get(state, :closures), :closing)

    records =
      (sessions ++ closures)
      |> Enum.sort_by(&inventory_record_sort_key/1)
      |> Enum.take(@max_inventory_records)

    observed_count = min(session_count + closure_count, @max_inventory_records)

    {records, observed_count,
     sessions_truncated or closures_truncated or
       session_count + closure_count > @max_inventory_records}
  end

  defp inventory_source_records(source, kind) when is_map(source) do
    records =
      source
      |> :maps.iterator()
      |> take_inventory_iterator(@max_inventory_records)
      |> Enum.sort_by(fn {key, _value} -> inventory_key_sort_key(key) end)
      |> Enum.map(fn {key, value} -> {kind, key, value} end)

    {records, min(map_size(source), @max_inventory_records),
     map_size(source) > @max_inventory_records}
  end

  defp inventory_source_records(_source, kind), do: {[{kind, nil, nil}], 1, false}

  defp take_inventory_iterator(iterator, limit), do: take_inventory_iterator(iterator, limit, [])

  defp take_inventory_iterator(_iterator, 0, acc), do: acc

  defp take_inventory_iterator(iterator, limit, acc) do
    case :maps.next(iterator) do
      :none ->
        acc

      {key, value, next_iterator} ->
        take_inventory_iterator(next_iterator, limit - 1, [{key, value} | acc])
    end
  end

  defp inventory_record_sort_key({kind, key, _value}) do
    {inventory_key_sort_key(key), if(kind == :registered, do: 0, else: 1)}
  end

  defp inventory_key_sort_key(key) when is_binary(key), do: {0, key}
  defp inventory_key_sort_key(_key), do: {1, ""}

  defp project_inventory_record({kind, key, raw_record}, liveness) do
    entry = if kind == :closing, do: inventory_value(raw_record, :entry), else: raw_record

    with true <- is_map(entry) and not is_struct(entry),
         {:ok, worker_session_id} <-
           inventory_required_id(inventory_value(entry, :worker_session_id)),
         true <- key == worker_session_id,
         {:ok, provider} <- inventory_provider(inventory_value(entry, :provider)),
         {:ok, model} <- inventory_optional_text(inventory_value(entry, :model)),
         {:ok, provider_session_id} <-
           inventory_optional_text(inventory_value(entry, :session_id)),
         {:ok, status} <- inventory_text(inventory_value(entry, :status)),
         true <- is_boolean(inventory_value(entry, :pooled)),
         true <- is_boolean(inventory_value(entry, :return_to_pool)),
         {:ok, task_id} <- inventory_optional_id(inventory_value(entry, :task_id)),
         {:ok, principal_id} <- inventory_optional_id(inventory_value(entry, :principal_id)) do
      live = Map.get(liveness, worker_session_id, %{})

      session = %{
        "worker_session_id" => worker_session_id,
        "provider_session_id" => provider_session_id,
        "provider" => provider,
        "model" => model,
        "status" => if(kind == :closing, do: "closing", else: status),
        "pooled" => inventory_value(entry, :pooled),
        "return_to_pool" => inventory_value(entry, :return_to_pool),
        "task_id" => task_id,
        "principal_id" => principal_id,
        "owner_present" => Map.get(live, :owner_present) == true,
        "owner_alive" => Map.get(live, :owner_alive) == true,
        "session_alive" => Map.get(live, :session_alive) == true,
        "close_cleanup_in_progress" => kind == :closing
      }

      identities =
        [{:worker_session, worker_session_id}]
        |> maybe_add_provider_identity(provider, provider_session_id)

      {:ok, session, identities}
    else
      _ -> :malformed
    end
  rescue
    _ -> :malformed
  catch
    _, _ -> :malformed
  end

  defp project_inventory_record(_record, _liveness), do: :malformed

  defp maybe_add_provider_identity(identities, _provider, nil), do: identities

  defp maybe_add_provider_identity(identities, provider, provider_session_id),
    do: [{:provider_session, provider, provider_session_id} | identities]

  defp inventory_matches?(session, filters) do
    matches_inventory_filter?(Map.get(filters, :task_id), session["task_id"]) and
      matches_inventory_filter?(Map.get(filters, :principal_id), session["principal_id"])
  end

  defp matches_inventory_filter?(nil, _actual), do: true
  defp matches_inventory_filter?(expected, actual), do: expected == actual

  defp inventory_sort_key(session) do
    {session["worker_session_id"], session["provider"] || "",
     session["provider_session_id"] || ""}
  end

  defp quarantine_entry({kind, key, raw_record}, reason) do
    entry = if kind == :closing, do: inventory_value(raw_record, :entry), else: raw_record
    worker_session_id = inventory_optional_id(inventory_value(entry, :worker_session_id))

    %{
      "kind" => if(kind == :closing, do: "close", else: "registered"),
      "reason" => reason
    }
    |> maybe_put_quarantine_id(worker_session_id)
    |> Map.put("source_key_valid", is_binary(key) and String.valid?(key))
  end

  defp maybe_put_quarantine_id(quarantine, {:ok, worker_session_id}),
    do: Map.put(quarantine, "worker_session_id", worker_session_id)

  defp maybe_put_quarantine_id(quarantine, _invalid), do: quarantine

  defp inventory_liveness(state) do
    state
    |> bounded_inventory_records()
    |> elem(0)
    |> Enum.reduce(%{}, fn {kind, _key, raw_record}, acc ->
      entry = if kind == :closing, do: inventory_value(raw_record, :entry), else: raw_record
      worker_session_id = inventory_value(entry, :worker_session_id)

      if is_binary(worker_session_id) do
        owner_pid = inventory_value(entry, :owner_pid)
        session_pid = inventory_value(entry, :session_pid)

        Map.put(acc, worker_session_id, %{
          owner_present: is_pid(owner_pid),
          owner_alive: process_alive?(owner_pid),
          session_alive: process_alive?(session_pid)
        })
      else
        acc
      end
    end)
  end

  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(_pid), do: false

  defp inventory_value(map, key, default \\ nil)
  defp inventory_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp inventory_value(_map, _key, default), do: default

  defp inventory_required_id(value), do: inventory_id(value, false)
  defp inventory_optional_id(nil), do: {:ok, nil}
  defp inventory_optional_id(value), do: inventory_id(value, true)

  defp inventory_id(value, _optional)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_inventory_id_bytes do
    if String.valid?(value) and String.trim(value) == value and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/) do
      {:ok, value}
    else
      :error
    end
  end

  defp inventory_id(_value, _optional), do: :error

  defp inventory_provider(value) when is_atom(value), do: inventory_text(Atom.to_string(value))
  defp inventory_provider(value), do: inventory_text(value)

  defp inventory_optional_text(nil), do: {:ok, nil}

  defp inventory_optional_text(value) when is_atom(value),
    do: inventory_optional_text(Atom.to_string(value))

  defp inventory_optional_text(value), do: inventory_text(value)

  defp inventory_text(value)
       when is_binary(value) and byte_size(value) <= @max_inventory_id_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      :error
    end
  end

  defp inventory_text(_value), do: :error

  defp invalid_inventory do
    %{
      "schema_version" => 1,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{"task_id" => nil, "principal_id" => nil},
      "max_items" => 0,
      "truncated" => true,
      "counts" => %{
        "observed" => 0,
        "matching" => 0,
        "returned" => 0,
        "filtered_out" => 0,
        "truncated" => 0,
        "malformed" => 1,
        "duplicates" => 0,
        "quarantined" => 1,
        "quarantine_returned" => 0,
        "quarantine_truncated" => 0
      },
      "sessions" => [],
      "quarantine" => []
    }
  end

  # Convert every GenServer.call exit (including timeout) into an error tuple
  # so acquisition cleanup in AcpManaged always runs after a failed register.
  defp call(message, opts) do
    with {:ok, opts, timeout} <- normalized_call_opts(opts) do
      call_normalized(message, opts, timeout)
    end
  end

  defp call_normalized(message, opts) do
    with {:ok, _opts, timeout} <- Arbor.AI.Timeout.remaining(opts) do
      call_normalized(message, opts, timeout)
    end
  end

  defp call_normalized(message, opts, timeout) do
    server = Keyword.get(opts, :server, @registry_name)

    try do
      GenServer.call(server, message, timeout)
    catch
      :exit, {:noproc, _} ->
        {:error, :registry_unavailable}

      :exit, {:normal, _} ->
        {:error, :registry_unavailable}

      :exit, {:shutdown, _} ->
        {:error, :registry_unavailable}

      :exit, {:timeout, _} ->
        {:error, :timeout}

      :exit, reason ->
        {:error, {:registry_call_failed, Arbor.LLM.sanitize_external_reason(reason)}}
    end
  end

  defp close_until(worker_session_id, caller, return_to_pool_override, opts, deadline) do
    reply_alias = :erlang.alias()
    operation_ref = make_ref()

    request = %{
      caller: caller,
      return_to_pool_override: return_to_pool_override,
      deadline_ms: deadline,
      cleanup_opts: Keyword.delete(opts, :server),
      operation_ref: operation_ref,
      reply_alias: reply_alias
    }

    try do
      case call_normalized({:close, worker_session_id, request}, opts) do
        {:ok, result, :committed} ->
          await_close_cleanup(operation_ref, result, opts)

        {:ok, result, :reconciled} ->
          {:ok, result}

        {:error, _reason} = error ->
          error
      end
    after
      :erlang.unalias(reply_alias)
    end
  end

  defp await_close_cleanup(operation_ref, result, opts) do
    with {:ok, _opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      receive do
        {^operation_ref, :close_cleanup, cleanup_result} ->
          with :ok <- Arbor.AI.Timeout.ensure_active(opts) do
            normalize_close_cleanup_result(cleanup_result, result)
          end
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp normalize_close_cleanup_result(:ok, result), do: {:ok, result}
  defp normalize_close_cleanup_result({:error, reason}, _result), do: {:error, reason}

  defp normalize_close_cleanup_result(other, _result),
    do: {:error, {:invalid_close_cleanup_result, Arbor.LLM.sanitize_external_reason(other)}}

  defp normalized_call_opts(opts) do
    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, 5_000),
         {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      {:ok, opts, remaining}
    end
  end

  defp split_caller_opts(opts) when is_list(opts) do
    timeout_keys = Arbor.LLM.timeout_option_keys()

    server_opts =
      Enum.filter(opts, fn
        {key, _value} when is_atom(key) ->
          key == :server or key == :deadline_ms or key in timeout_keys

        _invalid ->
          true
      end)

    caller = %{
      owner_pid: nil,
      task_id: normalize_id(Keyword.get(opts, :task_id)),
      principal_id: normalize_id(Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id))
    }

    {server_opts, caller}
  end

  defp split_caller_opts(opts) when is_map(opts) do
    server =
      case Map.get(opts, :server) || Map.get(opts, "server") do
        nil -> []
        name -> [server: name]
      end

    timeout = map_timeout_options(opts)

    principal =
      normalize_id(
        Map.get(opts, :principal_id) ||
          Map.get(opts, "principal_id") ||
          Map.get(opts, :agent_id) ||
          Map.get(opts, "agent_id")
      )

    caller = %{
      owner_pid: nil,
      task_id: normalize_id(Map.get(opts, :task_id) || Map.get(opts, "task_id")),
      principal_id: principal
    }

    {server ++ timeout, caller}
  end

  defp map_timeout_options(opts) do
    Enum.reduce([:deadline_ms | Arbor.LLM.timeout_option_keys()], [], fn key, acc ->
      acc = if Map.has_key?(opts, key), do: [{key, Map.get(opts, key)} | acc], else: acc
      string_key = Atom.to_string(key)

      if Map.has_key?(opts, string_key),
        do: [{key, Map.get(opts, string_key)} | acc],
        else: acc
    end)
  end

  defp deadline_active?(:infinity), do: true

  defp deadline_active?(deadline) when is_integer(deadline),
    do: System.monotonic_time(:millisecond) <= deadline

  defp deadline_active?(_deadline), do: false

  # Explicit close may override stored policy; :default keeps registration value.
  defp return_to_pool_override(opts) when is_list(opts) do
    case Keyword.fetch(opts, :return_to_pool) do
      {:ok, v} -> truthy?(v)
      :error -> :default
    end
  end

  defp return_to_pool_override(opts) when is_map(opts) do
    cond do
      Map.has_key?(opts, :return_to_pool) -> truthy?(Map.get(opts, :return_to_pool))
      Map.has_key?(opts, "return_to_pool") -> truthy?(Map.get(opts, "return_to_pool"))
      true -> :default
    end
  end

  defp apply_return_to_pool_override(entry, :default), do: entry

  defp apply_return_to_pool_override(entry, override) when is_boolean(override) do
    %{entry | return_to_pool: override}
  end

  defp normalize_register_attrs(attrs) do
    %{
      session_pid: Map.get(attrs, :session_pid) || Map.get(attrs, "session_pid"),
      session_module:
        Map.get(attrs, :session_module) || Map.get(attrs, "session_module") ||
          Arbor.AI.AcpSession,
      pool_module: Map.get(attrs, :pool_module) || Map.get(attrs, "pool_module"),
      provider: Map.get(attrs, :provider) || Map.get(attrs, "provider"),
      model: normalize_model(Map.get(attrs, :model) || Map.get(attrs, "model")),
      session_id: normalize_id(Map.get(attrs, :session_id) || Map.get(attrs, "session_id")),
      status: Map.get(attrs, :status) || Map.get(attrs, "status") || "ready",
      pooled: truthy?(Map.get(attrs, :pooled) || Map.get(attrs, "pooled")),
      return_to_pool:
        case Map.fetch(attrs, :return_to_pool) do
          {:ok, v} ->
            truthy?(v)

          :error ->
            case Map.fetch(attrs, "return_to_pool") do
              {:ok, v} -> truthy?(v)
              :error -> truthy?(Map.get(attrs, :pooled) || Map.get(attrs, "pooled"))
            end
        end,
      task_id: normalize_id(Map.get(attrs, :task_id) || Map.get(attrs, "task_id")),
      principal_id:
        normalize_id(
          Map.get(attrs, :principal_id) ||
            Map.get(attrs, "principal_id") ||
            Map.get(attrs, :agent_id) ||
            Map.get(attrs, "agent_id")
        )
    }
  end

  defp do_register(attrs, owner_pid, state) do
    with true <- is_pid(owner_pid) || {:error, :invalid_owner_pid},
         true <- Process.alive?(owner_pid) || {:error, :owner_dead},
         session_pid when is_pid(session_pid) <- attrs.session_pid,
         true <- Process.alive?(session_pid) || {:error, :session_dead},
         true <- is_atom(attrs.session_module) || {:error, :invalid_session_module} do
      # Monitor both before publishing the handle so a mid-register death is observed.
      owner_ref = Process.monitor(owner_pid)
      session_ref = Process.monitor(session_pid)
      worker_session_id = mint_handle()

      entry = %{
        worker_session_id: worker_session_id,
        session_pid: session_pid,
        session_ref: session_ref,
        session_module: attrs.session_module,
        pool_module: attrs.pool_module,
        owner_pid: owner_pid,
        owner_ref: owner_ref,
        provider: attrs.provider,
        model: attrs.model,
        session_id: attrs.session_id,
        status: status_string(attrs.status),
        pooled: attrs.pooled == true,
        return_to_pool: attrs.return_to_pool == true,
        task_id: attrs.task_id,
        principal_id: attrs.principal_id
      }

      state =
        state
        |> put_entry(entry)
        |> put_ref(entry.owner_ref, {:owner, worker_session_id})
        |> put_ref(entry.session_ref, {:session, worker_session_id})

      {:ok, public_view(entry), state}
    else
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_register, state}
      nil -> {:error, :invalid_session_pid, state}
      other when not is_pid(other) -> {:error, :invalid_session_pid, state}
    end
  end

  defp discard_registration(state, worker_session_id) do
    case Map.pop(state.sessions, worker_session_id) do
      {nil, _sessions} ->
        state

      {entry, sessions} ->
        Process.demonitor(entry.owner_ref, [:flush])
        Process.demonitor(entry.session_ref, [:flush])

        %{
          state
          | sessions: sessions,
            by_ref:
              state.by_ref
              |> Map.delete(entry.owner_ref)
              |> Map.delete(entry.session_ref)
        }
    end
  end

  defp resolve_view(entry) do
    %{
      worker_session_id: entry.worker_session_id,
      session_pid: entry.session_pid,
      session_module: entry.session_module,
      pool_module: entry.pool_module,
      provider: entry.provider,
      model: entry.model,
      session_id: entry.session_id,
      status: entry.status,
      pooled: entry.pooled,
      return_to_pool: entry.return_to_pool
    }
  end

  defp fetch_authorized(state, worker_session_id, caller) do
    case Map.fetch(state.sessions, worker_session_id) do
      :error ->
        {:error, :not_found}

      {:ok, entry} ->
        if authorized?(entry, caller) do
          if Process.alive?(entry.session_pid) do
            {:ok, entry}
          else
            {:error, :not_found}
          end
        else
          {:error, :not_authorized}
        end
    end
  end

  defp authorized?(entry, caller) do
    owner_match?(entry, caller) or principal_task_match?(entry, caller)
  end

  defp owner_match?(entry, caller) do
    is_pid(caller.owner_pid) and is_pid(entry.owner_pid) and caller.owner_pid == entry.owner_pid and
      Process.alive?(entry.owner_pid)
  end

  # Cross-process resume requires BOTH non-empty task_id and principal_id.
  # Task IDs alone are predictable identifiers, not capabilities.
  defp principal_task_match?(entry, caller) do
    non_empty_id?(entry.task_id) and non_empty_id?(caller.task_id) and
      entry.task_id == caller.task_id and
      non_empty_id?(entry.principal_id) and non_empty_id?(caller.principal_id) and
      entry.principal_id == caller.principal_id
  end

  defp non_empty_id?(id), do: is_binary(id) and id != ""

  defp handle_close_request(state, worker_session_id, caller, request) do
    case Map.fetch(state.closures, worker_session_id) do
      {:ok, closure} ->
        if authorized?(closure.entry, caller) do
          {:reply, {:ok, closing_view(closure.entry), :reconciled}, state}
        else
          {:reply, {:error, :not_authorized}, state}
        end

      :error ->
        handle_open_close_request(state, worker_session_id, caller, request)
    end
  end

  defp handle_open_close_request(state, worker_session_id, caller, request) do
    case Map.fetch(state.sessions, worker_session_id) do
      :error ->
        {:reply, {:ok, already_closed_view(worker_session_id), :reconciled}, state}

      {:ok, entry} ->
        cond do
          not authorized?(entry, caller) ->
            {:reply, {:error, :not_authorized}, state}

          not deadline_active?(request.deadline_ms) ->
            {:reply, {:error, :timeout}, state}

          true ->
            entry = apply_return_to_pool_override(entry, request.return_to_pool_override)
            {result, state} = commit_close(state, entry, request)
            {:reply, {:ok, result, :committed}, state}
        end
    end
  end

  defp commit_close(state, entry, request) do
    registry = self()
    worker_session_id = entry.worker_session_id

    # Cleanup ownership is established before the handle is removed. The
    # caller may time out or die after this point without orphaning the session.
    {cleanup_pid, cleanup_ref} =
      spawn_monitor(fn ->
        result = release_session_owned(entry, :close, request.cleanup_opts)

        send(
          registry,
          {:close_cleanup_complete, worker_session_id, request.operation_ref, result}
        )
      end)

    closure = %{
      worker_session_id: worker_session_id,
      operation_ref: request.operation_ref,
      reply_alias: request.reply_alias,
      cleanup_pid: cleanup_pid,
      cleanup_ref: cleanup_ref,
      entry: entry
    }

    state =
      state
      |> drop_entry(entry)
      |> put_closure(closure)
      |> put_ref(cleanup_ref, {:close_cleanup, worker_session_id, request.operation_ref})

    result =
      entry
      |> public_view()
      |> Map.put(:status, "closed")
      |> Map.put(:active, false)

    {result, state}
  end

  defp closing_view(entry) do
    entry
    |> public_view()
    |> Map.put(:status, "closing")
    |> Map.put(:active, false)
  end

  defp finish_closure(state, closure) do
    safe_demonitor(closure.cleanup_ref)

    %{
      state
      | closures: Map.delete(state.closures, closure.worker_session_id),
        by_ref: Map.delete(state.by_ref, closure.cleanup_ref)
    }
  end

  defp handle_cleanup_down(
         state,
         worker_session_id,
         operation_ref,
         cleanup_ref,
         reason
       ) do
    case Map.get(state.closures, worker_session_id) do
      %{operation_ref: ^operation_ref, cleanup_ref: ^cleanup_ref} = closure ->
        force_terminate(closure.entry.session_pid)

        cleanup_error =
          {:error, {:close_cleanup_worker_exit, Arbor.LLM.sanitize_external_reason(reason)}}

        safe_send_alias(
          closure.reply_alias,
          {operation_ref, :close_cleanup, cleanup_error}
        )

        Logger.debug(
          "AcpManaged: close cleanup owner exited for #{worker_session_id}: " <>
            Arbor.LLM.inspect_external_reason(reason)
        )

        %{state | closures: Map.delete(state.closures, worker_session_id)}

      _missing_or_stale ->
        state
    end
  end

  defp safe_send_alias(reply_alias, message) when is_reference(reply_alias) do
    send(reply_alias, message)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_send_alias(_reply_alias, _message), do: :ok

  defp handle_owner_down(state, worker_session_id, _pid, reason) do
    case Map.pop(state.sessions, worker_session_id) do
      {nil, _sessions} ->
        state

      {entry, sessions} ->
        Logger.debug(
          "AcpManaged: owner died for #{worker_session_id} (#{Arbor.LLM.inspect_external_reason(reason)}); releasing"
        )

        state = %{state | sessions: sessions}
        state = drop_ref(state, entry.session_ref)
        safe_demonitor(entry.session_ref)
        release_session(entry, :owner_death)
        state
    end
  end

  defp handle_session_down(state, worker_session_id, _pid, reason) do
    case Map.pop(state.sessions, worker_session_id) do
      {nil, _sessions} ->
        state

      {entry, sessions} ->
        Logger.debug(
          "AcpManaged: session died for #{worker_session_id} (#{Arbor.LLM.inspect_external_reason(reason)}); dropping handle"
        )

        state = %{state | sessions: sessions}
        state = drop_ref(state, entry.owner_ref)
        safe_demonitor(entry.owner_ref)
        state
    end
  end

  defp release_session(entry, reason) do
    Task.start(fn ->
      _ = release_session_owned(entry, reason, cleanup_opts())
    end)

    :ok
  end

  defp release_session_owned(entry, release_reason, opts) do
    case OwnedOperation.run(
           fn -> release_session_inline(entry, opts) end,
           opts,
           :timeout
         ) do
      :ok ->
        :ok

      {:error, _error_reason} = error ->
        force_terminate(entry.session_pid)

        Logger.debug(
          "AcpManaged: bounded release failed after #{release_reason}: " <>
            Arbor.LLM.inspect_external_reason(error)
        )

        error

      _other ->
        :ok
    end
  end

  defp release_session_inline(entry, opts) do
    cond do
      entry.pooled and entry.return_to_pool -> checkin_pooled(entry, opts)
      entry.pooled -> hard_close_pooled(entry, opts)
      true -> close_session_process_inline(entry, opts)
    end
  end

  defp checkin_pooled(entry, opts) do
    pool_mod = entry.pool_module || Arbor.AI.AcpPool

    cond do
      function_exported?(pool_mod, :checkin, 2) -> pool_mod.checkin(entry.session_pid, opts)
      function_exported?(pool_mod, :checkin, 1) -> pool_mod.checkin(entry.session_pid)
      true -> {:error, :pool_checkin_unavailable}
    end
  end

  defp hard_close_pooled(entry, opts) do
    pool_mod = entry.pool_module || Arbor.AI.AcpPool

    cond do
      function_exported?(pool_mod, :close_session, 2) ->
        pool_mod.close_session(entry.session_pid, opts)

      function_exported?(pool_mod, :close_session, 1) ->
        pool_mod.close_session(entry.session_pid)

      true ->
        close_session_process_inline(entry, opts)
    end
  end

  defp close_session_process_inline(entry, opts) do
    session_mod = entry.session_module || Arbor.AI.AcpSession
    pid = entry.session_pid

    if is_pid(pid) and Process.alive?(pid) do
      cond do
        function_exported?(session_mod, :close, 2) -> session_mod.close(pid, opts)
        function_exported?(session_mod, :close, 1) -> session_mod.close(pid)
        true -> force_terminate(pid)
      end
    end

    :ok
  end

  defp force_terminate(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp force_terminate(_pid), do: :ok

  defp cleanup_opts do
    {:ok, opts, _timeout} = Arbor.AI.Timeout.start_deadline([], @cleanup_timeout_ms)
    opts
  end

  defp put_entry(state, entry) do
    %{state | sessions: Map.put(state.sessions, entry.worker_session_id, entry)}
  end

  defp put_closure(state, closure) do
    %{state | closures: Map.put(state.closures, closure.worker_session_id, closure)}
  end

  defp put_ref(state, ref, tag) do
    %{state | by_ref: Map.put(state.by_ref, ref, tag)}
  end

  defp drop_entry(state, entry) do
    safe_demonitor(entry.owner_ref)
    safe_demonitor(entry.session_ref)

    %{
      state
      | sessions: Map.delete(state.sessions, entry.worker_session_id),
        by_ref:
          state.by_ref
          |> Map.delete(entry.owner_ref)
          |> Map.delete(entry.session_ref)
    }
  end

  defp drop_ref(state, ref) do
    %{state | by_ref: Map.delete(state.by_ref, ref)}
  end

  defp safe_demonitor(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp safe_demonitor(_), do: :ok

  defp mint_handle do
    @handle_prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp already_closed_view(worker_session_id) do
    %{
      worker_session_id: worker_session_id,
      session_id: nil,
      provider: nil,
      model: nil,
      status: "already_closed",
      pooled: false,
      active: false
    }
  end

  defp provider_string(nil), do: nil
  defp provider_string(p) when is_atom(p), do: Atom.to_string(p)
  defp provider_string(p) when is_binary(p), do: p
  defp provider_string(p), do: Arbor.LLM.inspect_external_reason(p)

  defp status_string(nil), do: "ready"
  defp status_string(s) when is_atom(s), do: Atom.to_string(s)
  defp status_string(s) when is_binary(s), do: s
  defp status_string(s), do: Arbor.LLM.inspect_external_reason(s)

  defp normalize_model(nil), do: nil
  defp normalize_model(m) when is_binary(m), do: m
  defp normalize_model(m) when is_atom(m), do: Atom.to_string(m)
  defp normalize_model(m), do: Arbor.LLM.inspect_external_reason(m)

  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_), do: nil

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?("true"), do: true
  defp truthy?("false"), do: false
  defp truthy?(1), do: true
  defp truthy?(0), do: false
  defp truthy?(_), do: false
end
