defmodule Arbor.Security.Telemetry do
  @moduledoc """
  Telemetry emission helpers for the security kernel.

  `arbor_security` owns the decision to emit security events, but not the
  decision to transport them on the signal bus. Emitting `:telemetry` events
  keeps the security kernel extractable; `arbor_signals` can attach a bridge
  when Arbor wants those events reflected as signals.
  """

  @event_prefix [:arbor, :security]
  @default_signal_category :security

  @signal_opt_keys [
    :cause_id,
    :correlation_id,
    :metadata,
    :scope,
    :source,
    :stream_id
  ]

  @doc """
  Emit a security telemetry event.

  The event name is `[:arbor, :security, type]`. Metadata includes a normalized
  signal payload so `Arbor.Signals.Telemetry` can bridge selected events without
  `arbor_security` depending on `arbor_signals` at the call site.
  """
  @spec emit(atom(), map(), keyword()) :: :ok
  def emit(type, data, opts \\ []) when is_atom(type) and is_map(data) do
    metadata = metadata(type, data, opts)

    :telemetry.execute(@event_prefix ++ [type], %{count: 1}, metadata)

    :ok
  rescue
    _ -> :ok
  end

  defp metadata(type, data, opts) do
    signal_data = Keyword.get(opts, :signal_data, data)

    %{
      category: @default_signal_category,
      type: type,
      data: data,
      signal_category: Keyword.get(opts, :signal_category, @default_signal_category),
      signal_type: Keyword.get(opts, :signal_type, type),
      signal_data: signal_data,
      signal_opts: signal_opts(opts),
      signal_durable: Keyword.get(opts, :signal_durable, Keyword.get(opts, :durable, false))
    }
  end

  defp signal_opts(opts) do
    opts
    |> Keyword.take(@signal_opt_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
