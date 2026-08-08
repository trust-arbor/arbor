defmodule Arbor.Historian.StreamContent.Core do
  @moduledoc false

  # Pure admit / progress / classification for complete-history stream content
  # convergence (VP-05D2C3I0C4C). No IO, Process, Application, or Persistence.
  #
  # Timeout: default 5000 ms, bound 1..60_000. The shell captures one outer
  # monotonic deadline; put_remaining_budget/3 only overwrites the per-call
  # remaining budget keys — timeouts are never reminted per stage.

  @max_stream_id_bytes 255
  @default_timeout_ms 5_000
  @max_timeout_ms 60_000
  @allowed_opt_keys [:timeout_ms]

  @type source :: :durable | :hot
  @type stage :: :durable_delete | :durable_verify | :hot_delete | :hot_verify
  @type proven_progress ::
          :none_proven_absent | :durable_proven_absent | :durable_and_hot_proven_absent

  @type pre_error ::
          :invalid_stream_id
          | :invalid_precondition
          | :durable_unavailable
          | :hot_unavailable
          | :delete_not_supported
          | :absence_not_supported
          | :verification_failed

  @type purge_class ::
          :dispatched_ok
          | {:pre, pre_error()}
          | :uncertain

  @type absence_class ::
          {:proof, boolean()}
          | {:pre, pre_error()}
          | :uncertain

  @spec admit(term(), term()) ::
          {:ok, %{timeout_ms: pos_integer()}}
          | {:error, :invalid_stream_id | :invalid_precondition}
  def admit(stream_id, opts) do
    with :ok <- validate_stream_id(stream_id),
         {:ok, timeout_ms} <- validate_opts(opts) do
      {:ok, %{timeout_ms: timeout_ms}}
    end
  end

  @spec remaining_ms(integer(), integer()) :: {:ok, pos_integer()} | :exhausted
  def remaining_ms(deadline_mono, now_mono)
      when is_integer(deadline_mono) and is_integer(now_mono) do
    remaining = deadline_mono - now_mono

    if remaining > 0, do: {:ok, remaining}, else: :exhausted
  end

  def remaining_ms(_deadline_mono, _now_mono), do: :exhausted

  @spec advance_progress(proven_progress(), source(), {:ok, true}) :: proven_progress()
  def advance_progress(:none_proven_absent, :durable, {:ok, true}), do: :durable_proven_absent

  def advance_progress(:durable_proven_absent, :hot, {:ok, true}),
    do: :durable_and_hot_proven_absent

  def advance_progress(progress, _source, _proof), do: progress

  @spec classify_purge_reply(source(), term()) :: purge_class()
  def classify_purge_reply(source, :ok) when source in [:durable, :hot], do: :dispatched_ok

  def classify_purge_reply(source, {:error, :backend_unavailable})
      when source in [:durable, :hot],
      do: {:pre, source_unavailable(source)}

  def classify_purge_reply(source, {:error, :purge_not_supported})
      when source in [:durable, :hot],
      do: {:pre, :delete_not_supported}

  def classify_purge_reply(source, {:error, :invalid_stream_id}) when source in [:durable, :hot],
    do: {:pre, :invalid_stream_id}

  def classify_purge_reply(source, {:error, :invalid_precondition})
      when source in [:durable, :hot],
      do: {:pre, :invalid_precondition}

  def classify_purge_reply(source, {:error, :purge_verification_failed})
      when source in [:durable, :hot],
      # May follow a dispatched purge — treat as post-effect uncertainty.
      do: :uncertain

  def classify_purge_reply(source, {:error, {:purge_indeterminate, _stream_id}})
      when source in [:durable, :hot],
      do: :uncertain

  def classify_purge_reply(source, _reply) when source in [:durable, :hot], do: :uncertain

  @spec classify_absence_reply(source(), term()) :: absence_class()
  def classify_absence_reply(source, {:ok, true}) when source in [:durable, :hot],
    do: {:proof, true}

  def classify_absence_reply(source, {:ok, false}) when source in [:durable, :hot],
    do: {:proof, false}

  def classify_absence_reply(source, {:error, :backend_unavailable})
      when source in [:durable, :hot],
      do: {:pre, source_unavailable(source)}

  def classify_absence_reply(source, {:error, :absence_not_supported})
      when source in [:durable, :hot],
      do: {:pre, :absence_not_supported}

  def classify_absence_reply(source, {:error, :invalid_stream_id})
      when source in [:durable, :hot],
      do: {:pre, :invalid_stream_id}

  def classify_absence_reply(source, {:error, :invalid_precondition})
      when source in [:durable, :hot],
      do: {:pre, :invalid_precondition}

  def classify_absence_reply(source, {:error, :absence_verification_failed})
      when source in [:durable, :hot],
      # Observation attempted but not proved — uncertain, never true.
      do: :uncertain

  def classify_absence_reply(source, {:error, {:absence_indeterminate, _stream_id}})
      when source in [:durable, :hot],
      do: :uncertain

  def classify_absence_reply(source, _reply) when source in [:durable, :hot], do: :uncertain

  @spec incomplete(String.t(), stage(), proven_progress()) ::
          {:error, {:delete_incomplete, String.t(), stage(), proven_progress()}}
  def incomplete(stream_id, stage, progress)
      when is_binary(stream_id) and
             stage in [:durable_delete, :durable_verify, :hot_delete, :hot_verify] and
             progress in [
               :none_proven_absent,
               :durable_proven_absent,
               :durable_and_hot_proven_absent
             ] do
    {:error, {:delete_incomplete, stream_id, stage, progress}}
  end

  @spec absence_indeterminate(String.t()) :: {:error, {:absence_indeterminate, String.t()}}
  def absence_indeterminate(stream_id) when is_binary(stream_id) do
    {:error, {:absence_indeterminate, stream_id}}
  end

  @spec put_remaining_budget(keyword(), :purge | :absence, pos_integer()) :: keyword()
  def put_remaining_budget(static_opts, :purge, remaining)
      when is_list(static_opts) and is_integer(remaining) and remaining > 0 do
    Keyword.put(static_opts, :purge_timeout_ms, remaining)
  end

  def put_remaining_budget(static_opts, :absence, remaining)
      when is_list(static_opts) and is_integer(remaining) and remaining > 0 do
    Keyword.put(static_opts, :absence_timeout_ms, remaining)
  end

  defp source_unavailable(:durable), do: :durable_unavailable
  defp source_unavailable(:hot), do: :hot_unavailable

  defp validate_stream_id(stream_id) when is_binary(stream_id) do
    byte_size = byte_size(stream_id)

    cond do
      byte_size == 0 -> {:error, :invalid_stream_id}
      byte_size > @max_stream_id_bytes -> {:error, :invalid_stream_id}
      not String.valid?(stream_id) -> {:error, :invalid_stream_id}
      true -> :ok
    end
  end

  defp validate_stream_id(_stream_id), do: {:error, :invalid_stream_id}

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
