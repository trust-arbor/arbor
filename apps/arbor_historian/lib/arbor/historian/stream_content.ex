defmodule Arbor.Historian.StreamContent do
  @moduledoc false

  # Imperative shell for complete-history stream content delete/absence
  # (VP-05D2C3I0C4C). Resolves Historian-owned Config targets, captures one
  # outer monotonic deadline from admitted timeout_ms (default 5000, bound
  # 1..60_000), and drives durable purge/verify followed by hot projection
  # eviction through the public Arbor.Persistence facade only. Read-only
  # absence consults only the durable complete-history authority. Each stage
  # receives only the remaining budget — timeouts are never reminted per stage.

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
         {:ok, durable} <- Config.durable_event_log_target() do
      deadline_mono = System.monotonic_time(:millisecond) + timeout_ms
      run_delete(stream_id, durable, deadline_mono, :none_proven_absent)
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
         {:ok, durable} <- Config.durable_event_log_target() do
      deadline_mono = System.monotonic_time(:millisecond) + timeout_ms
      observe(stream_id, :durable, durable, deadline_mono)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> Core.absence_indeterminate(stream_id_or_unknown(stream_id))
  catch
    kind, _reason when kind in [:exit, :throw, :error] ->
      Core.absence_indeterminate(stream_id_or_unknown(stream_id))
  end

  defp run_delete(stream_id, durable, deadline_mono, progress) do
    with :ok <-
           stage_purge(stream_id, :durable, :durable_delete, durable, deadline_mono, progress),
         {:ok, progress} <-
           stage_verify(stream_id, :durable, :durable_verify, durable, deadline_mono, progress) do
      stage_evict_hot(stream_id, deadline_mono, progress)
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
    # Durable verify runs only after a successful purge dispatch, so pre-dispatch
    # atoms still become incomplete (retryable) rather than bare pre-effect
    # errors that would hide the attempted durable delete.
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

  defp stage_evict_hot(stream_id, deadline_mono, progress) do
    case Config.hot_event_log_target() do
      {:ok, hot} ->
        case Core.remaining_ms(deadline_mono, System.monotonic_time(:millisecond)) do
          :exhausted ->
            Core.incomplete(stream_id, :hot_delete, progress)

          {:ok, remaining} ->
            opts = Core.put_remaining_budget(hot.opts, :eviction, remaining)
            reply = safe_evict(hot.name, hot.backend, stream_id, opts)

            case Core.classify_eviction_reply(reply) do
              :acknowledged -> :ok
              :uncertain -> Core.incomplete(stream_id, :hot_delete, progress)
            end
        end

      {:error, _reason} ->
        Core.incomplete(stream_id, :hot_delete, progress)
    end
  rescue
    _error -> Core.incomplete(stream_id, :hot_delete, progress)
  catch
    _kind, _reason -> Core.incomplete(stream_id, :hot_delete, progress)
  end

  defp safe_evict(name, backend, stream_id, opts) do
    Persistence.evict_projected_stream(name, backend, stream_id, opts)
  rescue
    _ -> {:error, :backend_unavailable}
  catch
    :exit, _ -> {:error, :backend_unavailable}
    :throw, _ -> {:error, :backend_unavailable}
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
