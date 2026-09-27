defmodule Arbor.Multimedia.Fence do
  @moduledoc false
  # A VM-lifetime atomics cell survives loss of the coordinating owner and resource
  # worker. Initialization is called only from the uniquely registered DeviceOwner
  # init, before admitting any worker; the cell is never erased or replaced.
  @key {__MODULE__, :device_custody}

  def init do
    case :persistent_term.get(@key, nil) do
      nil -> :persistent_term.put(@key, :atomics.new(1, signed: false))
      _ -> :ok
    end
  end

  def current do
    case :persistent_term.get(@key, nil) do
      nil ->
        nil

      cell ->
        case :atomics.get(cell, 1) do
          0 -> nil
          token -> token
        end
    end
  end

  def acquire(token) when is_integer(token) and token > 0 do
    case :atomics.compare_exchange(:persistent_term.get(@key), 1, 0, token) do
      :ok -> :ok
      _ -> {:error, :device_busy}
    end
  end

  def release(token) when is_integer(token) and token > 0 do
    _ = :atomics.compare_exchange(:persistent_term.get(@key), 1, token, 0)
    :ok
  end

  def release(_), do: :ok
end
