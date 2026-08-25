defmodule Arbor.KernelRuntime.BootProfileBinding.Testing do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ExUnit.Callbacks],
    exports: :all

  @now_key {__MODULE__, :now}
  @block_key {__MODULE__, :block}
  @waiting_key {__MODULE__, :waiting}
  @fixture_now "2026-08-17T00:00:00Z"

  @spec now() :: String.t()
  def now do
    await_open()
    timestamp()
  end

  @spec put_now(String.t()) :: :ok
  def put_now(timestamp) when is_binary(timestamp) do
    :persistent_term.put(@now_key, timestamp)
    :ok
  end

  @spec block_now() :: :ok
  def block_now do
    :persistent_term.put(@waiting_key, false)
    :persistent_term.put(@block_key, :blocked)
    :ok
  end

  @spec unblock_now(String.t()) :: :ok
  def unblock_now(timestamp) when is_binary(timestamp) do
    put_now(timestamp)
    :persistent_term.put(@block_key, :open)
    :ok
  end

  @spec now_waiting?() :: boolean()
  def now_waiting? do
    :persistent_term.get(@waiting_key, false) == true
  end

  @spec reset_clock() :: :ok
  def reset_clock do
    :persistent_term.put(@block_key, :open)
    :persistent_term.put(@waiting_key, false)
    :persistent_term.put(@now_key, @fixture_now)
    :ok
  end

  defp timestamp do
    case :persistent_term.get(@now_key, :unset) do
      :unset -> @fixture_now
      ts when is_binary(ts) -> ts
    end
  end

  defp await_open do
    case :persistent_term.get(@block_key, :open) do
      :open ->
        :ok

      :blocked ->
        :persistent_term.put(@waiting_key, true)
        poll_open()
    end
  end

  defp poll_open do
    case :persistent_term.get(@block_key, :open) do
      :open ->
        :ok

      :blocked ->
        receive do
        after
          10 -> poll_open()
        end
    end
  end
end
