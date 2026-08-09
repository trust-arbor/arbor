defmodule Arbor.Memory.Events.ContentCore do
  @moduledoc false

  # Pure admit / deadline / report transitions for exact-agent Memory event
  # content composition (Voice C4D). No IO, Process, Application, or facades.

  @max_agent_id_bytes 248
  @stream_prefix "memory:"
  @default_timeout_ms 5_000
  @max_timeout_ms 60_000
  @allowed_opt_keys [:timeout_ms]
  @authority_order [:signals, :local_event_log, :historian, :maintenance_archive]

  @type authority ::
          :signals | :local_event_log | :historian | :maintenance_archive

  @type status ::
          :absent
          | :present
          | :delete_succeeded_unverified
          | :delete_failed
          | :delete_indeterminate
          | :absence_indeterminate
          | :not_attempted_deadline

  @type report :: %{
          signals: status(),
          local_event_log: status(),
          historian: status(),
          maintenance_archive: status()
        }

  @type admitted :: %{
          agent_id: String.t(),
          stream_id: String.t(),
          timeout_ms: pos_integer()
        }

  @type delete_result ::
          :ok
          | {:error, :invalid_agent_id | :invalid_precondition}
          | {:error, {:cleanup_incomplete, String.t(), report()}}

  @type absence_result ::
          {:ok, boolean()}
          | {:error, :invalid_agent_id | :invalid_precondition}
          | {:error, {:absence_indeterminate, String.t(), report()}}

  @spec authority_order() :: [authority()]
  def authority_order, do: @authority_order

  @spec stream_id(String.t()) :: String.t()
  def stream_id(agent_id) when is_binary(agent_id), do: @stream_prefix <> agent_id

  @spec admit(term(), term()) ::
          {:ok, admitted()} | {:error, :invalid_agent_id | :invalid_precondition}
  def admit(agent_id, opts) do
    with {:ok, agent_id} <- validate_agent_id(agent_id),
         {:ok, timeout_ms} <- validate_opts(opts) do
      {:ok,
       %{
         agent_id: agent_id,
         stream_id: stream_id(agent_id),
         timeout_ms: timeout_ms
       }}
    end
  end

  @spec remaining_ms(integer(), integer()) :: {:ok, pos_integer()} | :exhausted
  def remaining_ms(deadline_mono, now_mono)
      when is_integer(deadline_mono) and is_integer(now_mono) do
    remaining = deadline_mono - now_mono

    cond do
      remaining <= 0 -> :exhausted
      remaining > @max_timeout_ms -> {:ok, @max_timeout_ms}
      true -> {:ok, remaining}
    end
  end

  def remaining_ms(_deadline_mono, _now_mono), do: :exhausted

  @spec init_delete_report() :: report()
  def init_delete_report do
    Map.new(@authority_order, fn key -> {key, :not_attempted_deadline} end)
  end

  @spec init_absence_report() :: report()
  def init_absence_report, do: init_delete_report()

  # Outer rescue/catch progress is unknown: never claim :not_attempted_deadline
  # unless the composite deadline actually prevented an attempt.
  @spec exception_delete_report() :: report()
  def exception_delete_report do
    Map.new(@authority_order, fn key -> {key, :delete_indeterminate} end)
  end

  @spec exception_absence_report() :: report()
  def exception_absence_report do
    Map.new(@authority_order, fn key -> {key, :absence_indeterminate} end)
  end

  @spec put_status(report(), authority(), status()) :: report()
  def put_status(report, key, status)
      when is_map(report) and key in @authority_order and
             status in [
               :absent,
               :present,
               :delete_succeeded_unverified,
               :delete_failed,
               :delete_indeterminate,
               :absence_indeterminate,
               :not_attempted_deadline
             ] do
    Map.put(report, key, status)
  end

  @spec apply_verify_result(report(), authority(), :absent | :present | :uncertain) :: report()
  def apply_verify_result(report, key, :absent) when key in @authority_order do
    put_status(report, key, :absent)
  end

  def apply_verify_result(report, key, :present) when key in @authority_order do
    put_status(report, key, :present)
  end

  def apply_verify_result(report, key, :uncertain) when key in @authority_order do
    case Map.fetch!(report, key) do
      authoritative when authoritative in [:absent, :present] ->
        report

      _other ->
        put_status(report, key, :absence_indeterminate)
    end
  end

  @spec classify_delete_reply(authority(), term()) :: status()
  def classify_delete_reply(_authority, :ok), do: :delete_succeeded_unverified

  def classify_delete_reply(_authority, {:error, reason})
      when reason in [
             :invalid_agent_id,
             :invalid_stream_id,
             :invalid_precondition,
             :store_unavailable,
             :checkpoint_configuration_invalid,
             :checkpoint_unavailable,
             :checkpoint_verification_failed,
             :purge_not_supported,
             :delete_not_supported,
             :backend_unavailable,
             :durable_unavailable,
             :hot_unavailable,
             :verification_failed
           ] do
    :delete_failed
  end

  def classify_delete_reply(_authority, {:error, {:delete_indeterminate, _}}),
    do: :delete_indeterminate

  def classify_delete_reply(_authority, {:error, {:purge_indeterminate, _}}),
    do: :delete_indeterminate

  def classify_delete_reply(_authority, {:error, {:delete_incomplete, _, _, _}}),
    do: :delete_indeterminate

  def classify_delete_reply(_authority, _reply), do: :delete_indeterminate

  @spec classify_absence_reply(authority(), term()) :: :absent | :present | :uncertain
  def classify_absence_reply(_authority, {:ok, true}), do: :absent
  def classify_absence_reply(_authority, {:ok, false}), do: :present
  def classify_absence_reply(_authority, _reply), do: :uncertain

  @spec finalize_delete(String.t(), report()) :: delete_result()
  def finalize_delete(agent_id, report) when is_binary(agent_id) and is_map(report) do
    if all_absent?(report) do
      :ok
    else
      {:error, {:cleanup_incomplete, agent_id, report}}
    end
  end

  @spec finalize_absence(String.t(), report()) :: absence_result()
  def finalize_absence(agent_id, report) when is_binary(agent_id) and is_map(report) do
    statuses = Enum.map(@authority_order, &Map.fetch!(report, &1))

    cond do
      Enum.any?(statuses, &(&1 == :present)) ->
        {:ok, false}

      Enum.all?(statuses, &(&1 == :absent)) ->
        {:ok, true}

      true ->
        {:error, {:absence_indeterminate, agent_id, report}}
    end
  end

  @spec put_persistence_budget(keyword(), :purge | :absence, pos_integer()) :: keyword()
  def put_persistence_budget(static_opts, :purge, remaining)
      when is_list(static_opts) and is_integer(remaining) and remaining > 0 do
    Keyword.put(static_opts, :purge_timeout_ms, remaining)
  end

  def put_persistence_budget(static_opts, :absence, remaining)
      when is_list(static_opts) and is_integer(remaining) and remaining > 0 do
    Keyword.put(static_opts, :absence_timeout_ms, remaining)
  end

  @spec facade_timeout_opts(pos_integer()) :: keyword()
  def facade_timeout_opts(remaining)
      when is_integer(remaining) and remaining > 0 and remaining <= @max_timeout_ms do
    [timeout_ms: remaining]
  end

  @spec all_absent?(report()) :: boolean()
  def all_absent?(report) when is_map(report) do
    Enum.all?(@authority_order, fn key -> Map.fetch!(report, key) == :absent end)
  end

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    byte_size = byte_size(agent_id)

    cond do
      byte_size < 1 or byte_size > @max_agent_id_bytes ->
        {:error, :invalid_agent_id}

      not String.valid?(agent_id) ->
        {:error, :invalid_agent_id}

      match?({_pos, _len}, :binary.match(agent_id, <<0>>)) ->
        {:error, :invalid_agent_id}

      true ->
        {:ok, agent_id}
    end
  end

  defp validate_agent_id(_), do: {:error, :invalid_agent_id}

  defp validate_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and unique_keys?(opts) and closed_opt_keys?(opts) do
      case Keyword.fetch(opts, :timeout_ms) do
        :error ->
          {:ok, @default_timeout_ms}

        {:ok, timeout_ms}
        when is_integer(timeout_ms) and timeout_ms >= 1 and timeout_ms <= @max_timeout_ms ->
          {:ok, timeout_ms}

        {:ok, _invalid} ->
          {:error, :invalid_precondition}
      end
    else
      {:error, :invalid_precondition}
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_precondition}

  defp unique_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp closed_opt_keys?(opts) do
    Enum.all?(Keyword.keys(opts), &(&1 in @allowed_opt_keys))
  end
end
