defmodule Arbor.Shell.ValidationRuntime do
  @moduledoc """
  Boot-pinned dispatcher for spawn-capable validation runtimes.

  Implementations own probe/execute/status. Production start in this slice
  pins Apple Container; Application env cannot select a backend. Checkout
  returns the pinned module; `execute/3` runs in the caller so a Mix unit
  cannot occupy the authority GenServer.
  """

  alias Arbor.Shell.ValidationRuntime.Authority

  @callback probe() :: {:ok, map()} | {:error, term()}
  @callback execute(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  @callback public_status() :: map()

  @doc false
  @spec execute(term(), term(), term()) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, args, opts) do
    case Authority.checkout_implementation() do
      {:ok, mod} -> mod.execute(tool_name, args, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec probe() :: {:ok, map()} | {:error, term()}
  def probe do
    case Authority.checkout_implementation() do
      {:ok, mod} -> mod.probe()
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec public_status() :: map()
  def public_status, do: Authority.public_status()
end
