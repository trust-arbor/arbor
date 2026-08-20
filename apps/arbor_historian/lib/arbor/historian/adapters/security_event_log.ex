defmodule Arbor.Historian.Adapters.SecurityEventLog do
  @moduledoc """
  Historian-owned adapter for `Arbor.Security.Contracts.EventLogAdapter`.

  Translates Security event envelopes onto the existing `security:events`
  EventLog stream used by the live host, and reads that same stream back.
  """

  @behaviour Arbor.Security.Contracts.EventLogAdapter

  alias Arbor.Historian.Config
  alias Arbor.Persistence
  alias Arbor.Persistence.Event

  @stream_id "security:events"

  @impl true
  def persist_security_event(event_type, data)
      when is_atom(event_type) and is_map(data) do
    with {:ok, target} <- ready_hot_target() do
      event =
        Event.new(
          @stream_id,
          to_string(event_type),
          Map.put(data, :timestamp, DateTime.utc_now()),
          metadata: %{source_node: node()}
        )

      case Persistence.append(target.name, target.backend, @stream_id, event, target.opts) do
        {:ok, _stored} -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, :event_log_unavailable}
      end
    end
  end

  def persist_security_event(_event_type, _data), do: {:error, :invalid_event}

  @impl true
  def read_security_events(opts) when is_list(opts) do
    with {:ok, target} <- ready_hot_target() do
      Persistence.read_stream(
        target.name,
        target.backend,
        @stream_id,
        Keyword.merge(target.opts, opts)
      )
    end
  end

  def read_security_events(_opts), do: {:error, :event_log_unavailable}

  defp ready_hot_target do
    case Config.hot_event_log_target() do
      {:ok, target} ->
        if loaded?(target.backend) and is_pid(Process.whereis(target.name)) do
          {:ok, target}
        else
          {:error, :event_log_unavailable}
        end

      {:error, _reason} ->
        {:error, :event_log_unavailable}
    end
  end

  defp loaded?(backend) when is_atom(backend) and not is_nil(backend) do
    match?({:module, _}, Code.ensure_loaded(backend))
  end

  defp loaded?(_backend), do: false
end
