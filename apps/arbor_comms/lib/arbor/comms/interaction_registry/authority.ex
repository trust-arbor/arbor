defmodule Arbor.Comms.InteractionRegistry.Authority do
  @moduledoc false

  use GenServer

  require Logger

  alias Arbor.Contracts.Comms.ApprovalAnswer
  alias Arbor.Contracts.Comms.Interaction

  @pending_topic "interactions"
  @terminal_topic "interactions:resolved"
  @terminal_ttl_ms 120_000
  @terminal_max_entries 512

  @type terminal_status :: :responded | :abandoned | :expired

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec put(Interaction.t()) :: {:ok, Interaction.t()} | {:error, term()}
  def put(%Interaction{} = interaction) do
    call({:put, interaction})
  end

  @spec pending(String.t()) :: {:ok, Interaction.t()} | :not_found
  def pending(request_id) when is_binary(request_id) do
    call({:pending, request_id})
  end

  @spec terminal(String.t()) :: {:ok, map()} | :not_found
  def terminal(request_id) when is_binary(request_id) do
    call({:terminal, request_id})
  end

  @spec status(String.t()) :: {:ok, :pending | terminal_status()} | :not_found
  def status(request_id) when is_binary(request_id) do
    call({:status, request_id})
  end

  @spec respond(String.t(), term(), map()) ::
          {:ok, Interaction.t()} | {:error, {:already_terminal, terminal_status()}} | :not_found
  def respond(request_id, response, metadata)
      when is_binary(request_id) and is_map(metadata) do
    call({:respond, request_id, response, metadata})
  end

  @spec abandon(String.t(), atom() | String.t()) ::
          {:ok, Interaction.t() | :already_abandoned}
          | {:error, {:already_terminal, terminal_status()}}
          | :not_found
  def abandon(request_id, reason)
      when is_binary(request_id) and (is_atom(reason) or is_binary(reason)) do
    call({:abandon, request_id, reason})
  end

  @spec arm_timeout(String.t(), non_neg_integer()) ::
          {:ok, %{authority_pid: pid(), outcome: :armed | {:terminal, map()}}} | :not_found
  def arm_timeout(request_id, timeout_ms)
      when is_binary(request_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    call({:arm_timeout, request_id, timeout_ms})
  end

  @spec finalize_timeout(pid(), String.t()) :: {:ok, map()} | {:error, term()} | :not_found
  def finalize_timeout(authority_pid, request_id)
      when is_pid(authority_pid) and is_binary(request_id) do
    call(authority_pid, {:finalize_timeout, request_id})
  end

  @spec reset() :: :ok
  def reset do
    call(:reset)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       tracker: Keyword.get(opts, :tracker, Arbor.Comms.InteractionRegistry)
     }}
  end

  @impl true
  def handle_call({:put, %Interaction{request_id: request_id} = interaction}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      nil ->
        case mirror_pending(state.tracker, interaction) do
          :ok ->
            entry = %{status: :pending, interaction: interaction, owner_deadline: nil}
            next_state = state |> put_in([:entries, request_id], entry) |> expire_due_pending()
            {:reply, {:ok, interaction}, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      %{status: :pending, interaction: existing} ->
        {:reply, {:ok, existing}, state}

      %{status: status} ->
        {:reply, {:error, {:already_terminal, status}}, state}
    end
  end

  def handle_call({:pending, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    reply =
      case Map.get(state.entries, request_id) do
        %{status: :pending, interaction: interaction} -> {:ok, interaction}
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:terminal, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    reply =
      case Map.get(state.entries, request_id) do
        %{status: status, terminal: terminal} when status != :pending -> {:ok, terminal}
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:status, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    reply =
      case Map.get(state.entries, request_id) do
        %{status: status} -> {:ok, status}
        nil -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:respond, request_id, response, metadata}, _from, state) do
    transition(
      state,
      request_id,
      fn interaction, now ->
        %{
          status: :responded,
          decision: approval_decision(interaction, response, metadata),
          response: response,
          metadata: bound_metadata(metadata),
          reason: nil,
          resolved_at: now,
          authority_node: node()
        }
      end,
      nil
    )
  end

  def handle_call({:abandon, request_id, reason}, _from, state) do
    transition(
      state,
      request_id,
      fn _interaction, now ->
        %{
          status: :abandoned,
          decision: nil,
          response: nil,
          metadata: %{},
          reason: bound_reason(reason),
          resolved_at: now,
          authority_node: node()
        }
      end,
      :abandoned
    )
  end

  def handle_call({:arm_timeout, request_id, timeout_ms}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      %{status: :pending} = entry ->
        deadline = earliest_deadline(entry.owner_deadline, timeout_ms)
        state = put_in(state.entries[request_id].owner_deadline, deadline)
        state = expire_due_pending(state)

        outcome =
          case Map.fetch!(state.entries, request_id) do
            %{status: :pending} -> :armed
            %{terminal: terminal} -> {:terminal, terminal}
          end

        {:reply, {:ok, %{authority_pid: self(), outcome: outcome}}, state}

      %{terminal: terminal} ->
        {:reply, {:ok, %{authority_pid: self(), outcome: {:terminal, terminal}}}, state}

      nil ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:finalize_timeout, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      %{status: :pending, interaction: interaction} ->
        {terminal, next_state} =
          terminalize(state, request_id, interaction, :abandoned, :await_timeout)

        {:reply, {:ok, terminal}, next_state}

      %{terminal: terminal} ->
        {:reply, {:ok, terminal}, state}

      nil ->
        {:reply, :not_found, state}
    end
  end

  def handle_call(:reset, _from, state) do
    _ = safe_untrack_all(state.tracker)
    {:reply, :ok, %{state | entries: %{}}}
  end

  defp transition(state, request_id, terminal_builder, idempotent_status) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      %{status: :pending, interaction: interaction} ->
        terminal = terminal_builder.(interaction, System.system_time(:millisecond))
        entry = %{status: terminal.status, interaction: interaction, terminal: terminal}
        next_state = put_in(state.entries[request_id], entry)

        mirror_terminal(state.tracker, request_id, terminal)
        {:reply, {:ok, interaction}, next_state}

      %{status: status} when status == idempotent_status ->
        {:reply, {:ok, :already_abandoned}, state}

      %{status: status} ->
        {:reply, {:error, {:already_terminal, status}}, state}

      nil ->
        {:reply, :not_found, state}
    end
  end

  defp mirror_pending(tracker, %Interaction{request_id: request_id} = interaction) do
    meta = %{interaction: interaction, authority_node: node()}

    case Phoenix.Tracker.track(tracker, self(), @pending_topic, request_id, meta) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _, _, _}} -> :ok
      {:error, reason} -> {:error, {:tracker_unavailable, reason}}
    end
  rescue
    error -> {:error, {:tracker_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:tracker_unavailable, reason}}
  end

  defp mirror_terminal(tracker, request_id, terminal) do
    case Phoenix.Tracker.track(tracker, self(), @terminal_topic, request_id, terminal) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _, _, _}} -> :ok
      {:error, reason} -> log_mirror_failure(request_id, reason)
    end

    safe_untrack(tracker, @pending_topic, request_id)
    :ok
  rescue
    error ->
      log_mirror_failure(request_id, Exception.message(error))
      :ok
  catch
    :exit, reason ->
      log_mirror_failure(request_id, reason)
      :ok
  end

  defp safe_untrack(tracker, topic, request_id) do
    Phoenix.Tracker.untrack(tracker, self(), topic, request_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_untrack_all(tracker) do
    Phoenix.Tracker.untrack(tracker, self())
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp log_mirror_failure(request_id, reason) do
    Logger.warning(
      "[InteractionRegistry.Authority] terminal mirror failed for #{request_id}: #{inspect(reason)}"
    )
  end

  defp approval_decision(%Interaction{kind: :approval}, response, metadata) do
    case ApprovalAnswer.normalize(response, metadata) do
      {:ok, :approve} -> :approved
      {:ok, :deny, _note} -> :rejected
      {:ok, :rework, _note} -> :rejected
      {:error, _reason} -> nil
    end
  end

  defp approval_decision(%Interaction{}, _response, _metadata), do: nil

  defp bound_metadata(metadata) when is_map(metadata) do
    note = Map.get(metadata, :note) || Map.get(metadata, "note")

    case note do
      value when is_binary(value) ->
        bounded = bound_reason(value)

        metadata
        |> Map.put(:note, bounded)
        |> Map.delete("note")

      _ ->
        metadata
    end
  end

  defp bound_reason(reason) when is_atom(reason), do: reason

  defp bound_reason(reason) when is_binary(reason) do
    case ApprovalAnswer.validate_note(reason, truncate: true, drop_invalid: true) do
      {:ok, bounded} -> bounded
      _ -> ""
    end
  end

  defp expire_due_pending(state) do
    now = DateTime.utc_now()
    monotonic_now = System.monotonic_time(:millisecond)
    resolved_at = DateTime.to_unix(now, :millisecond)

    Enum.reduce(state.entries, state, fn
      {request_id, %{status: :pending, interaction: interaction} = entry}, acc ->
        cond do
          expired?(interaction.expires_at, now) ->
            terminalize(acc, request_id, interaction, :expired, :expires_at_elapsed, resolved_at)
            |> elem(1)

          deadline_elapsed?(entry.owner_deadline, monotonic_now) ->
            terminalize(acc, request_id, interaction, :abandoned, :await_timeout, resolved_at)
            |> elem(1)

          true ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp expired?(nil, _now), do: false

  defp expired?(%DateTime{} = expires_at, now) do
    DateTime.compare(expires_at, now) in [:lt, :eq]
  end

  defp expired?(expires_at, now) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, parsed, _offset} -> expired?(parsed, now)
      _ -> false
    end
  end

  defp expired?(_expires_at, _now), do: false

  defp earliest_deadline(nil, timeout_ms) do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp earliest_deadline(existing_deadline, timeout_ms) when is_integer(existing_deadline) do
    min(existing_deadline, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp deadline_elapsed?(nil, _monotonic_now), do: false
  defp deadline_elapsed?(deadline, monotonic_now), do: deadline <= monotonic_now

  defp terminalize(state, request_id, interaction, status, reason, resolved_at \\ nil) do
    resolved_at = resolved_at || System.system_time(:millisecond)

    terminal = %{
      status: status,
      decision: nil,
      response: nil,
      metadata: %{},
      reason: reason,
      resolved_at: resolved_at,
      authority_node: node()
    }

    entry = %{status: status, interaction: interaction, terminal: terminal}
    mirror_terminal(state.tracker, request_id, terminal)
    {terminal, put_in(state.entries[request_id], entry)}
  end

  defp prune_terminals(state) do
    now = System.system_time(:millisecond)

    terminal_entries =
      state.entries
      |> Enum.flat_map(fn
        {request_id, %{status: status, terminal: %{resolved_at: resolved_at}}}
        when status != :pending and is_integer(resolved_at) ->
          [{request_id, resolved_at}]

        _ ->
          []
      end)
      |> Enum.sort_by(fn {_request_id, resolved_at} -> resolved_at end, :desc)

    expired =
      terminal_entries
      |> Enum.filter(fn {_request_id, resolved_at} -> now - resolved_at > @terminal_ttl_ms end)
      |> Enum.map(&elem(&1, 0))

    over_limit =
      terminal_entries
      |> Enum.reject(fn {request_id, _resolved_at} -> request_id in expired end)
      |> Enum.drop(@terminal_max_entries)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(Enum.uniq(expired ++ over_limit), state, fn request_id, acc ->
      safe_untrack(acc.tracker, @terminal_topic, request_id)
      update_in(acc.entries, &Map.delete(&1, request_id))
    end)
  end

  defp call(message) do
    call(__MODULE__, message)
  end

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :authority_unavailable}
  end
end
