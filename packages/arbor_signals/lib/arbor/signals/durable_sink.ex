defmodule Arbor.Signals.DurableSink do
  @moduledoc false

  require Logger

  alias Arbor.Signals.Config

  @spec dispatch(String.t(), term(), map(), keyword()) ::
          :ok
          | {:error, :persist_failed}
          | {:skip, atom()}
          | {:skip, :provider_raised, module()}
  def dispatch(stream_id, event_type, data, opts) do
    bounded = take_bounded_opts(opts)

    case resolve(Config.durable_sink_module()) do
      {:ok, provider} ->
        provider
        |> invoke(fn mod -> mod.persist_durable_event(stream_id, event_type, data, bounded) end)
        |> normalize()
        |> observe(stream_id)

      {:skip, :absent} = skip ->
        skip

      {:skip, _reason} = skip ->
        observe(skip, stream_id)
    end
  end

  @spec take_bounded_opts(keyword()) :: keyword()
  def take_bounded_opts(opts) when is_list(opts) do
    []
    |> maybe_put(:correlation_id, fetch_opt(opts, :correlation_id))
    |> maybe_put(:cause_id, fetch_opt(opts, :cause_id))
    |> maybe_put(:agent_id, fetch_opt(opts, :agent_id))
    |> put_metadata(opts)
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :__absent__
      {:ok, value} -> value
    end
  end

  defp maybe_put(acc, _key, :__absent__), do: acc
  defp maybe_put(acc, _key, nil), do: acc
  defp maybe_put(acc, key, value), do: Keyword.put(acc, key, value)

  defp put_metadata(acc, opts) do
    case Keyword.fetch(opts, :metadata) do
      :error -> acc
      {:ok, meta} when is_map(meta) -> Keyword.put(acc, :metadata, meta)
      {:ok, _} -> Keyword.put(acc, :metadata, %{})
    end
  end

  defp resolve(nil), do: {:skip, :absent}
  defp resolve(true), do: {:skip, :invalid_provider}
  defp resolve(false), do: {:skip, :invalid_provider}
  defp resolve(provider) when not is_atom(provider), do: {:skip, :invalid_provider}

  defp resolve(provider) do
    case Code.ensure_loaded(provider) do
      {:module, _} ->
        if function_exported?(provider, :persist_durable_event, 4) do
          {:ok, provider}
        else
          {:skip, :missing_callback}
        end

      _ ->
        {:skip, :missing_callback}
    end
  end

  defp invoke(provider, fun) do
    fun.(provider)
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    :throw, _ -> :threw
    :exit, _ -> :exited
  end

  defp normalize(:ok), do: :ok
  defp normalize({:error, :persist_failed}), do: {:error, :persist_failed}
  defp normalize({:raised, mod}), do: {:skip, :provider_raised, mod}
  defp normalize(:threw), do: {:skip, :provider_threw}
  defp normalize(:exited), do: {:skip, :provider_exited}
  defp normalize(_other), do: {:skip, :malformed_result}

  defp observe(:ok, _stream_id), do: :ok

  defp observe({:error, :persist_failed} = result, stream_id) do
    log_gap(stream_id, :persist_failed)
    result
  end

  defp observe({:skip, :provider_raised, mod} = result, stream_id) do
    Logger.warning(
      "[Signals.durable_emit] persistence gap stream=#{format_stream_id(stream_id)} reason=provider_raised module=#{inspect(mod)}"
    )

    result
  end

  defp observe({:skip, reason} = result, stream_id) do
    log_gap(stream_id, reason)
    result
  end

  @stream_id_log_max_bytes 64

  defp log_gap(stream_id, reason) do
    Logger.warning(
      "[Signals.durable_emit] persistence gap stream=#{format_stream_id(stream_id)} reason=#{reason}"
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
