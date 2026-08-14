defmodule Arbor.Historian.DurableSignalSink do
  @moduledoc false

  require Logger

  alias Arbor.Historian.Config
  alias Arbor.Persistence
  alias Arbor.Persistence.Event

  @spec persist(String.t(), term(), map(), keyword()) :: :ok | {:error, :persist_failed}
  def persist(stream_id, event_type, data, opts) do
    case construct(stream_id, event_type, data, opts) do
      {:ok, event} ->
        case append_hot(stream_id, event) do
          :ok ->
            spawn_durable(stream_id, event)
            :ok

          :raised ->
            {:error, :persist_failed}
        end

      {:error, :persist_failed} = error ->
        error
    end
  rescue
    _ ->
      {:error, :persist_failed}
  catch
    kind, _reason when kind in [:throw, :exit] ->
      {:error, :persist_failed}
  end

  defp construct(stream_id, event_type, data, opts) do
    {:ok, build_event(stream_id, event_type, data, opts)}
  rescue
    _ ->
      log_gap(stream_id, :event_construction_failed)
      {:error, :persist_failed}
  catch
    kind, _reason when kind in [:throw, :exit] ->
      log_gap(stream_id, :event_construction_failed)
      {:error, :persist_failed}
  end

  defp build_event(stream_id, event_type, data, opts) do
    Event.new(
      stream_id,
      to_string(event_type),
      Map.put(data, :timestamp, DateTime.utc_now()),
      event_opts(opts)
    )
  end

  defp event_opts(opts) when is_list(opts) do
    caller_meta =
      case Keyword.get(opts, :metadata, %{}) do
        meta when is_map(meta) -> meta
        _ -> %{}
      end

    metadata =
      caller_meta
      |> Map.drop([:source_node, "source_node"])
      |> Map.put(:source_node, node())

    [metadata: metadata]
    |> put_present(:correlation_id, Keyword.get(opts, :correlation_id))
    |> put_present(:causation_id, Keyword.get(opts, :cause_id))
    |> put_present(:agent_id, Keyword.get(opts, :agent_id))
  end

  defp put_present(kw, _key, nil), do: kw
  defp put_present(kw, key, value), do: Keyword.put(kw, key, value)

  defp append_hot(stream_id, event) do
    case Config.hot_event_log_target() do
      {:error, _} ->
        log_gap(stream_id, :hot_target_invalid)
        :ok

      {:ok, target} ->
        cond do
          not loaded?(target.backend) ->
            log_gap(stream_id, :hot_backend_unavailable)
            :ok

          is_nil(Process.whereis(target.name)) ->
            log_gap(stream_id, :hot_unavailable)
            :ok

          true ->
            dispatch_hot(stream_id, event, target)
        end
    end
  rescue
    _ ->
      log_gap(stream_id, :hot_append_failed)
      :raised
  catch
    kind, _reason when kind in [:throw, :exit] ->
      log_gap(stream_id, :hot_append_failed)
      :raised
  end

  defp dispatch_hot(stream_id, event, target) do
    case Persistence.append(target.name, target.backend, stream_id, event, target.opts) do
      {:ok, _} -> :ok
      _ -> log_gap(stream_id, :hot_append_failed)
    end

    :ok
  end

  defp spawn_durable(stream_id, event) do
    case Config.durable_event_log_target() do
      {:error, _} ->
        log_gap(stream_id, :durable_target_invalid)

      {:ok, target} ->
        case durable_ready?(target) do
          :ok ->
            start_durable_task(stream_id, event, target)

          {:gap, reason} ->
            log_gap(stream_id, reason)
        end
    end
  end

  defp durable_ready?(target) do
    cond do
      not loaded?(target.backend) ->
        {:gap, :durable_backend_unavailable}

      Keyword.has_key?(target.opts, :repo) ->
        if is_pid(Process.whereis(Keyword.get(target.opts, :repo))) do
          :ok
        else
          {:gap, :durable_repo_unavailable}
        end

      is_pid(Process.whereis(target.name)) ->
        :ok

      true ->
        {:gap, :durable_unavailable}
    end
  end

  defp start_durable_task(stream_id, event, target) do
    starter = Application.get_env(:arbor_historian, :durable_task_starter, &Task.start/1)

    result =
      try do
        starter.(fn -> durable_append(stream_id, event, target) end)
      rescue
        _ -> :spawn_failed
      catch
        :throw, _ -> :spawn_failed
        :exit, _ -> :spawn_failed
      end

    case result do
      {:ok, pid} when is_pid(pid) -> :ok
      _ -> log_gap(stream_id, :durable_spawn_failed)
    end
  end

  defp durable_append(stream_id, event, target) do
    case Persistence.append(target.name, target.backend, stream_id, event, target.opts) do
      {:ok, _} -> :ok
      _ -> log_gap(stream_id, :durable_append_failed)
    end
  rescue
    _ ->
      log_gap(stream_id, :durable_append_raised)
  catch
    kind, _reason when kind in [:throw, :exit] ->
      log_gap(stream_id, :durable_append_raised)
  end

  defp loaded?(backend) when is_atom(backend) do
    match?({:module, _}, Code.ensure_loaded(backend))
  end

  defp loaded?(_backend), do: false

  @stream_id_log_max_bytes 64

  defp log_gap(stream_id, reason) do
    Logger.warning(
      "[Historian.durable_sink] persistence gap stream=#{format_stream_id(stream_id)} reason=#{reason}"
    )
  end

  defp format_stream_id(stream_id) when is_binary(stream_id) do
    take = min(byte_size(stream_id), @stream_id_log_max_bytes)
    prefix = binary_part(stream_id, 0, take)
    rendered = sanitize_stream_prefix(prefix)

    if byte_size(stream_id) > @stream_id_log_max_bytes do
      rendered <> "..."
    else
      rendered
    end
  rescue
    _ -> "<invalid>"
  end

  defp format_stream_id(_stream_id), do: "<invalid>"

  defp sanitize_stream_prefix(prefix) do
    for <<byte <- prefix>>, into: <<>> do
      if stream_id_log_byte?(byte), do: <<byte>>, else: "?"
    end
  end

  defp stream_id_log_byte?(byte)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?., ?:, ?-],
       do: true

  defp stream_id_log_byte?(_byte), do: false
end
