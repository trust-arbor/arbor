defmodule Arbor.Historian.StreamContent do
  @moduledoc false

  # Imperative shell for complete-history stream content delete/absence
  # (VP-05D2C3I0C4C). Resolves Historian-owned Config targets, captures one
  # outer monotonic deadline from admitted timeout_ms (default 5000, bound
  # 1..60_000), and drives durable→hot purge/verify via the public
  # Arbor.Persistence facade only. Each stage receives only the remaining
  # budget — timeouts are never reminted per stage.

  alias Arbor.Historian.Config
  alias Arbor.Historian.StreamContent.Core
  alias Arbor.Persistence

  @type delete_result ::
          :ok
          | {:error, {:delete_incomplete, String.t(), Core.stage(), Core.proven_progress()}}
          | {:error, Core.pre_error()}

  @type absence_result ::
          {:ok, true}
          | {:ok, false}
          | {:error, {:absence_indeterminate, String.t()}}
          | {:error, Core.pre_error()}

  @spec delete(String.t(), keyword()) :: delete_result()
  def delete(stream_id, opts \\ []) do
    with {:ok, %{timeout_ms: timeout_ms}} <- Core.admit(stream_id, opts),
         {:ok, durable} <- Config.durable_event_log_target(),
         {:ok, hot} <- Config.hot_event_log_target() do
      deadline_mono = System.monotonic_time(:millisecond) + timeout_ms
      run_delete(stream_id, durable, hot, deadline_mono, :none_proven_absent)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> Core.incomplete(stream_id_or_unknown(stream_id), :durable_delete, :none_proven_absent)
  catch
    kind, _reason when kind in [:exit, :throw, :error] ->
      Core.incomplete(stream_id_or_unknown(stream_id), :durable_delete, :none_proven_absent)
  end

  @spec absent?(String.t(), keyword()) :: absence_result()
  def absent?(stream_id, opts \\ []) do
    with {:ok, %{timeout_ms: timeout_ms}} <- Core.admit(stream_id, opts),
         {:ok, durable} <- Config.durable_event_log_target(),
         {:ok, hot} <- Config.hot_event_log_target() do
      deadline_mono = System.monotonic_time(:millisecond) + timeout_ms
      run_absent(stream_id, durable, hot, deadline_mono)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> Core.absence_indeterminate(stream_id_or_unknown(stream_id))
  catch
    kind, _reason when kind in [:exit, :throw, :error] ->
      Core.absence_indeterminate(stream_id_or_unknown(stream_id))
  end

  defp run_delete(stream_id, durable, hot, deadline_mono, progress) do
    with :ok <-
           stage_purge(stream_id, :durable, :durable_delete, durable, deadline_mono, progress),
         {:ok, progress} <-
           stage_verify(stream_id, :durable, :durable_verify, durable, deadline_mono, progress),
         :ok <- stage_purge(stream_id, :hot, :hot_delete, hot, deadline_mono, progress),
         {:ok, _progress} <-
           stage_verify(stream_id, :hot, :hot_verify, hot, deadline_mono, progress) do
      :ok
    end
  end

  defp stage_purge(stream_id, source, stage, target, deadline_mono, progress) do
    case Core.remaining_ms(deadline_mono, System.monotonic_time(:millisecond)) do
      :exhausted ->
        Core.incomplete(stream_id, stage, progress)

      {:ok, remaining} ->
        opts = Core.put_remaining_budget(target.opts, :purge, remaining)
        reply = safe_purge(target.name, target.backend, stream_id, opts)
        map_purge_stage(stream_id, source, stage, progress, reply)
    end
  end

  defp stage_verify(stream_id, source, stage, target, deadline_mono, progress) do
    case Core.remaining_ms(deadline_mono, System.monotonic_time(:millisecond)) do
      :exhausted ->
        Core.incomplete(stream_id, stage, progress)

      {:ok, remaining} ->
        opts = Core.put_remaining_budget(target.opts, :absence, remaining)
        reply = safe_absent(target.name, target.backend, stream_id, opts)
        map_verify_stage(stream_id, source, stage, progress, reply)
    end
  end

  # Bare pre-dispatch atoms only for true durable pre-effect failures with no
  # proven progress. Once durable is proven (or any non-pre-dispatch purge
  # failure occurs), report delete_incomplete with exact stage + progress so
  # retries retain machine-readable partial progress (Rev 2 hot-stage envelopes).
  defp map_purge_stage(stream_id, source, stage, progress, reply) do
    case Core.classify_purge_reply(source, reply) do
      :dispatched_ok ->
        :ok

      {:pre, reason}
      when progress == :none_proven_absent and stage == :durable_delete ->
        {:error, reason}

      {:pre, _reason} ->
        Core.incomplete(stream_id, stage, progress)

      :uncertain ->
        Core.incomplete(stream_id, stage, progress)
    end
  end

  defp map_verify_stage(stream_id, source, stage, progress, reply) do
    # Verify stages only run after a successful purge dispatch for that source, so
    # pre-dispatch atoms still become incomplete (retryable) rather than bare
    # pre-effect errors that would hide the attempted durable/hot delete.
    case Core.classify_absence_reply(source, reply) do
      {:proof, true} ->
        next = Core.advance_progress(progress, source, {:ok, true})
        {:ok, next}

      {:proof, false} ->
        Core.incomplete(stream_id, stage, progress)

      {:pre, _reason} ->
        Core.incomplete(stream_id, stage, progress)

      :uncertain ->
        Core.incomplete(stream_id, stage, progress)
    end
  end

  defp run_absent(stream_id, durable, hot, deadline_mono) do
    with {:ok, durable_proof} <- observe(stream_id, :durable, durable, deadline_mono),
         {:ok, hot_proof} <- observe(stream_id, :hot, hot, deadline_mono) do
      cond do
        durable_proof and hot_proof -> {:ok, true}
        true -> {:ok, false}
      end
    end
  end

  defp observe(stream_id, source, target, deadline_mono) do
    case Core.remaining_ms(deadline_mono, System.monotonic_time(:millisecond)) do
      :exhausted ->
        Core.absence_indeterminate(stream_id)

      {:ok, remaining} ->
        opts = Core.put_remaining_budget(target.opts, :absence, remaining)
        reply = safe_absent(target.name, target.backend, stream_id, opts)

        case Core.classify_absence_reply(source, reply) do
          {:proof, value} -> {:ok, value}
          {:pre, reason} -> {:error, reason}
          :uncertain -> Core.absence_indeterminate(stream_id)
        end
    end
  end

  defp safe_purge(name, backend, stream_id, opts) do
    Persistence.purge_stream(name, backend, stream_id, opts)
  rescue
    _ -> {:error, {:purge_indeterminate, stream_id}}
  catch
    :exit, _ -> {:error, {:purge_indeterminate, stream_id}}
    :throw, _ -> {:error, {:purge_indeterminate, stream_id}}
  end

  defp safe_absent(name, backend, stream_id, opts) do
    Persistence.event_stream_absent?(name, backend, stream_id, opts)
  rescue
    _ -> {:error, {:absence_indeterminate, stream_id}}
  catch
    :exit, _ -> {:error, {:absence_indeterminate, stream_id}}
    :throw, _ -> {:error, {:absence_indeterminate, stream_id}}
  end

  defp stream_id_or_unknown(stream_id) when is_binary(stream_id) and stream_id != "",
    do: stream_id

  defp stream_id_or_unknown(_), do: "unknown"
end
