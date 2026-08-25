defmodule Arbor.KernelRuntime.BootProfileBinding.Testing do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ExUnit.Callbacks],
    exports: :all

  @now_key {__MODULE__, :now}
  @fixture_now "2026-08-17T00:00:00Z"

  @spec now() :: String.t()
  def now do
    case :persistent_term.get(@now_key, :unset) do
      :unset -> @fixture_now
      ts when is_binary(ts) -> ts
    end
  end

  @spec put_now(String.t()) :: :ok
  def put_now(timestamp) when is_binary(timestamp) do
    :persistent_term.put(@now_key, timestamp)
    :ok
  end
end
