defmodule Arbor.Historian.Adapters.SecurityEventLog do
  @moduledoc """
  Historian-owned adapter for `Arbor.Security.Contracts.EventLogAdapter`.

  Translates Security event envelopes onto the existing `security:events`
  EventLog stream used by the live host, and reads that same stream back.
  """

  @behaviour Arbor.Security.Contracts.EventLogAdapter

  alias Arbor.Historian.Config
  alias Arbor.Persistence

  @stream_id "security:events"
  @read_controls [:from, :limit, :direction]

  @impl true
  def persist_security_event(event_type, data)
      when is_atom(event_type) and is_map(data) do
    case Arbor.Historian.persist_durable_event(@stream_id, event_type, data, []) do
      :ok -> :ok
      {:error, :persist_failed} = error -> error
      _other -> {:error, :persist_failed}
    end
  rescue
    _error -> {:error, :persist_failed}
  catch
    _kind, _reason -> {:error, :persist_failed}
  end

  def persist_security_event(_event_type, _data), do: {:error, :invalid_event}

  @impl true
  def read_security_events(opts) when is_list(opts) do
    with {:ok, target} <- durable_target(),
         :ok <- reject_projection_mode(target),
         read_opts <- authoritative_read_opts(opts, target.opts),
         {:ok, events} <- read_authoritative(target, read_opts) do
      {:ok, events}
    else
      _failure -> {:error, :event_log_unavailable}
    end
  rescue
    _error -> {:error, :event_log_unavailable}
  catch
    _kind, _reason -> {:error, :event_log_unavailable}
  end

  def read_security_events(_opts), do: {:error, :event_log_unavailable}

  defp durable_target do
    case Config.durable_event_log_target() do
      {:ok, %{name: name, backend: backend, opts: opts} = target}
      when is_atom(name) and not is_nil(name) and is_atom(backend) and not is_nil(backend) and
             is_list(opts) ->
        {:ok, target}

      _failure ->
        {:error, :event_log_unavailable}
    end
  end

  defp reject_projection_mode(target) do
    if Persistence.supports_projection?(target.backend) do
      case Persistence.resident_projected_stream_version(
             target.name,
             target.backend,
             @stream_id,
             target.opts
           ) do
        {:error, :projection_mode_required} -> :ok
        _projection_or_failure -> {:error, :event_log_unavailable}
      end
    else
      :ok
    end
  end

  defp authoritative_read_opts(caller_opts, target_opts) do
    caller_opts
    |> Keyword.take(@read_controls)
    |> Keyword.merge(target_opts)
  end

  defp read_authoritative(target, opts) do
    case Persistence.read_stream(target.name, target.backend, @stream_id, opts) do
      {:ok, events} when is_list(events) ->
        if Enum.all?(events, &valid_event?/1) do
          {:ok, events}
        else
          {:error, :event_log_unavailable}
        end

      _failure ->
        {:error, :event_log_unavailable}
    end
  end

  defp valid_event?(event) when is_map(event) do
    type = Map.get(event, :type)
    data = Map.get(event, :data)
    (is_atom(type) or is_binary(type)) and is_map(data)
  end

  defp valid_event?(_event), do: false
end
