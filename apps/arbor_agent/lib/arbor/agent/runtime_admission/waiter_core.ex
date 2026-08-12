defmodule Arbor.Agent.RuntimeAdmission.WaiterCore do
  @moduledoc """
  Pure decision core for runtime-admission waiters (Phase 4C C3C1a0 F-575).

  No IO, no GenServer, no Process. TaskStore is the imperative shell for
  monitor, timer, cancel, demonitor, reply, and mailbox effects.

  Waiter bookkeeping never launches, stops, retries, settles, or otherwise
  drives the underlying runtime-start intent.
  """

  @ceiling 64

  @type from :: GenServer.from()
  @type waiter_id :: reference()
  @type intent_id :: String.t()

  @type record :: %{
          waiter_id: waiter_id(),
          intent_id: intent_id(),
          from: from(),
          caller_pid: pid(),
          mon: reference(),
          deadline_token: reference(),
          timer_ref: reference()
        }

  @type waiters :: %{optional(intent_id()) => %{optional(waiter_id()) => record()}}
  @type by_mon :: %{optional(reference()) => {intent_id(), waiter_id()}}
  @type by_deadline :: %{optional(reference()) => {intent_id(), waiter_id()}}

  @doc "Hard production ceiling for waiters per intent."
  @spec ceiling() :: 64
  def ceiling, do: @ceiling

  @doc """
  Normalize a trusted store max. Tests may lower (1..64); values above the
  ceiling clamp to 64; invalid values become the default ceiling.
  """
  @spec normalize_max(term()) :: pos_integer()
  def normalize_max(n) when is_integer(n) and n >= 1 and n <= @ceiling, do: n
  def normalize_max(n) when is_integer(n) and n > @ceiling, do: @ceiling
  def normalize_max(_), do: @ceiling

  @doc "Effective cap is never above the hard ceiling."
  @spec effective_max(term()) :: pos_integer()
  def effective_max(max), do: min(normalize_max(max), @ceiling)

  @spec can_accept?(non_neg_integer(), term()) ::
          :ok | {:error, :runtime_admission_waiters_full}
  def can_accept?(count, max)
      when is_integer(count) and count >= 0 do
    if count >= effective_max(max) do
      {:error, :runtime_admission_waiters_full}
    else
      :ok
    end
  end

  @spec intent_count(waiters(), intent_id()) :: non_neg_integer()
  def intent_count(waiters, intent_id) when is_map(waiters) and is_binary(intent_id) do
    case Map.get(waiters, intent_id) do
      %{} = bucket -> map_size(bucket)
      _ -> 0
    end
  end

  @spec insert(waiters(), by_mon(), by_deadline(), record(), term()) ::
          {:ok, waiters(), by_mon(), by_deadline()}
          | {:error, :runtime_admission_waiters_full | :duplicate_authority | :invalid_record}
  def insert(waiters, by_mon, by_dl, record, max)
      when is_map(waiters) and is_map(by_mon) and is_map(by_dl) and is_map(record) do
    with :ok <- validate_record(record),
         :ok <- can_accept?(intent_count(waiters, record.intent_id), max),
         :ok <- reject_duplicate_authority(waiters, by_mon, by_dl, record) do
      intent_id = record.intent_id
      waiter_id = record.waiter_id
      bucket = Map.get(waiters, intent_id, %{})
      waiters = Map.put(waiters, intent_id, Map.put(bucket, waiter_id, record))
      by_mon = Map.put(by_mon, record.mon, {intent_id, waiter_id})
      by_dl = Map.put(by_dl, record.deadline_token, {intent_id, waiter_id})
      {:ok, waiters, by_mon, by_dl}
    end
  end

  def insert(_, _, _, _, _), do: {:error, :invalid_record}

  @spec remove_by_mon(waiters(), by_mon(), by_deadline(), reference()) ::
          {:ok, record(), waiters(), by_mon(), by_deadline()} | :stale
  def remove_by_mon(waiters, by_mon, by_dl, mon)
      when is_map(waiters) and is_map(by_mon) and is_map(by_dl) and is_reference(mon) do
    case Map.get(by_mon, mon) do
      {intent_id, waiter_id} ->
        pop_record(waiters, by_mon, by_dl, intent_id, waiter_id, :mon, mon)

      _ ->
        :stale
    end
  end

  def remove_by_mon(_, _, _, _), do: :stale

  @spec remove_by_deadline(waiters(), by_mon(), by_deadline(), reference()) ::
          {:ok, record(), waiters(), by_mon(), by_deadline()} | :stale
  def remove_by_deadline(waiters, by_mon, by_dl, token)
      when is_map(waiters) and is_map(by_mon) and is_map(by_dl) and is_reference(token) do
    case Map.get(by_dl, token) do
      {intent_id, waiter_id} ->
        pop_record(waiters, by_mon, by_dl, intent_id, waiter_id, :deadline_token, token)

      _ ->
        :stale
    end
  end

  def remove_by_deadline(_, _, _, _), do: :stale

  @spec detach_all(waiters(), by_mon(), by_deadline(), intent_id()) ::
          {[record()], waiters(), by_mon(), by_deadline()}
  def detach_all(waiters, by_mon, by_dl, intent_id)
      when is_map(waiters) and is_map(by_mon) and is_map(by_dl) and is_binary(intent_id) do
    case Map.get(waiters, intent_id) do
      %{} = bucket when map_size(bucket) > 0 ->
        records = Map.values(bucket)

        by_mon =
          Enum.reduce(records, by_mon, fn rec, acc ->
            Map.delete(acc, rec.mon)
          end)

        by_dl =
          Enum.reduce(records, by_dl, fn rec, acc ->
            Map.delete(acc, rec.deadline_token)
          end)

        {records, Map.delete(waiters, intent_id), by_mon, by_dl}

      _ ->
        {[], Map.delete(waiters, intent_id), by_mon, by_dl}
    end
  end

  @doc """
  One-time repair for waiters + mon index + deadline index.

  Surviving records must have exact shape, matching unique indexes, and no
  orphan index entries. Indexes are rebuilt only from surviving records.
  Returns records that could not be retained so callers can classify the state
  as corrupt. Not for the hot path after schema migration.
  """
  @spec normalize_correlated(term(), term(), term()) ::
          {waiters(), by_mon(), by_deadline(), [record()]}
  def normalize_correlated(waiters, by_mon, by_dl) do
    waiters = if is_map(waiters), do: waiters, else: %{}
    by_mon = if is_map(by_mon), do: by_mon, else: %{}
    by_dl = if is_map(by_dl), do: by_dl, else: %{}

    # Collect every map-shaped record candidate (index match checked later).
    all_records =
      Enum.flat_map(waiters, fn
        {intent_id, %{} = bucket} when is_binary(intent_id) ->
          Enum.flat_map(bucket, fn
            {waiter_id, record} when is_reference(waiter_id) and is_map(record) ->
              [Map.put(record, :__bucket_key, {intent_id, waiter_id})]

            _ ->
              []
          end)

        _ ->
          []
      end)

    # First pass: keep only records with exact shape + matching indexes.
    {candidates, shape_dropped} =
      Enum.split_with(all_records, fn record ->
        {intent_id, waiter_id} = record.__bucket_key

        case validate_record(Map.delete(record, :__bucket_key)) do
          :ok ->
            record.intent_id == intent_id and record.waiter_id == waiter_id and
              Map.get(by_mon, record.mon) == {intent_id, waiter_id} and
              Map.get(by_dl, record.deadline_token) == {intent_id, waiter_id}

          _ ->
            false
        end
      end)

    candidates = Enum.map(candidates, &Map.delete(&1, :__bucket_key))
    shape_dropped = Enum.map(shape_dropped, &Map.delete(&1, :__bucket_key))

    # Second pass: enforce mon/token uniqueness (first-seen wins for rebuild).
    {kept, dup_dropped, _seen_mon, _seen_tok} =
      Enum.reduce(candidates, {[], [], MapSet.new(), MapSet.new()}, fn rec,
                                                                       {acc, dropped, mons, toks} ->
        cond do
          MapSet.member?(mons, rec.mon) ->
            {acc, [rec | dropped], mons, toks}

          MapSet.member?(toks, rec.deadline_token) ->
            {acc, [rec | dropped], mons, toks}

          true ->
            {[rec | acc], dropped, MapSet.put(mons, rec.mon),
             MapSet.put(toks, rec.deadline_token)}
        end
      end)

    kept = Enum.reverse(kept)
    {waiters_n, by_mon_n, by_dl_n} = rebuild(kept)
    dropped = shape_dropped ++ Enum.reverse(dup_dropped)
    {waiters_n, by_mon_n, by_dl_n, dropped}
  end

  @doc "Whether the three waiter indexes already satisfy the exact invariant."
  @spec correlated?(term(), term(), term()) :: boolean()
  def correlated?(waiters, by_mon, by_dl) do
    {waiters_n, by_mon_n, by_dl_n, dropped} =
      normalize_correlated(waiters, by_mon, by_dl)

    dropped == [] and waiters_n == waiters and by_mon_n == by_mon and by_dl_n == by_dl
  end

  @doc """
  Classify a per-intent waiter bucket for hot-state migration.

  - `:modern_map` — map of waiter records (may still need correlated normalize)
  - `{:legacy_from_list, froms}` — pre-F-575 list of GenServer.from values
  - `:corrupt` — unrecoverable shape with no reply channel
  - `:empty` — nil/missing
  """
  @spec classify_legacy(term()) ::
          :empty | :modern_map | {:legacy_from_list, [from()]} | :corrupt
  def classify_legacy(nil), do: :empty
  def classify_legacy(%{}), do: :modern_map

  def classify_legacy(list) when is_list(list) do
    if Enum.all?(list, &valid_from?/1) do
      {:legacy_from_list, list}
    else
      :corrupt
    end
  end

  def classify_legacy(_), do: :corrupt

  @spec extract_legacy_drains(term()) :: [{intent_id(), [from()]}]
  def extract_legacy_drains(waiters) when is_map(waiters) do
    Enum.flat_map(waiters, fn
      {intent_id, bucket} when is_binary(intent_id) ->
        case classify_legacy(bucket) do
          {:legacy_from_list, froms} -> [{intent_id, froms}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  def extract_legacy_drains(_), do: []

  # ── private ──────────────────────────────────────────────────────────

  defp pop_record(waiters, by_mon, by_dl, intent_id, waiter_id, auth_field, auth_value) do
    with %{} = record <- get_in(waiters, [intent_id, waiter_id]),
         :ok <- validate_record(record),
         true <-
           correlated_record?(record, by_mon, by_dl, intent_id, waiter_id, auth_field, auth_value) do
      remove_record(waiters, by_mon, by_dl, intent_id, waiter_id, record)
    else
      _ -> :stale
    end
  end

  defp correlated_record?(record, by_mon, by_dl, intent_id, waiter_id, auth_field, auth_value) do
    Map.get(record, auth_field) == auth_value and
      Map.get(by_mon, record.mon) == {intent_id, waiter_id} and
      Map.get(by_dl, record.deadline_token) == {intent_id, waiter_id}
  end

  defp remove_record(waiters, by_mon, by_dl, intent_id, waiter_id, record) do
    bucket = waiters |> Map.fetch!(intent_id) |> Map.delete(waiter_id)

    waiters =
      if map_size(bucket) == 0,
        do: Map.delete(waiters, intent_id),
        else: Map.put(waiters, intent_id, bucket)

    {:ok, record, waiters, Map.delete(by_mon, record.mon),
     Map.delete(by_dl, record.deadline_token)}
  end

  defp reject_duplicate_authority(waiters, by_mon, by_dl, record) do
    cond do
      get_in(waiters, [record.intent_id, record.waiter_id]) != nil ->
        {:error, :duplicate_authority}

      Map.has_key?(by_mon, record.mon) ->
        {:error, :duplicate_authority}

      Map.has_key?(by_dl, record.deadline_token) ->
        {:error, :duplicate_authority}

      true ->
        :ok
    end
  end

  defp validate_record(
         %{
           waiter_id: waiter_id,
           intent_id: intent_id,
           from: from,
           caller_pid: caller_pid,
           mon: mon,
           deadline_token: token,
           timer_ref: timer_ref
         } = record
       )
       when is_reference(waiter_id) and is_binary(intent_id) and is_pid(caller_pid) and
              is_reference(mon) and is_reference(token) and is_reference(timer_ref) do
    if map_size(record) == 7 and valid_from?(from) and elem(from, 0) == caller_pid do
      :ok
    else
      {:error, :invalid_record}
    end
  end

  defp validate_record(_), do: {:error, :invalid_record}

  # `GenServer.from()` deliberately leaves the reply tag as `term()`; modern
  # OTP calls commonly use an alias-form improper list rather than a reference.
  # Caller authority is the envelope PID plus the shell-owned monitor, not tag shape.
  defp valid_from?({pid, _tag}) when is_pid(pid), do: true

  defp valid_from?(_), do: false

  defp rebuild(records) do
    Enum.reduce(records, {%{}, %{}, %{}}, fn rec, {waiters, by_mon, by_dl} ->
      bucket = Map.get(waiters, rec.intent_id, %{})
      waiters = Map.put(waiters, rec.intent_id, Map.put(bucket, rec.waiter_id, rec))
      by_mon = Map.put(by_mon, rec.mon, {rec.intent_id, rec.waiter_id})
      by_dl = Map.put(by_dl, rec.deadline_token, {rec.intent_id, rec.waiter_id})
      {waiters, by_mon, by_dl}
    end)
  end
end
