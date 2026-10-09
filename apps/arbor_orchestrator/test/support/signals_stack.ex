defmodule Arbor.Orchestrator.TestSupport.SignalsStack do
  @moduledoc false

  # config/test.exs leaves the signals supervisor empty. Authenticated bus
  # calls accept only Store and Bus that are children of that supervisor.
  # An ExUnit start_supervised process registered under the same name is
  # rejected as :unauthorized, and durable_emit then never reaches the sink.

  @needed [Arbor.Signals.Store, Arbor.Signals.Bus]

  @spec ensure!() :: :ok
  def ensure! do
    {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    sup = Arbor.Signals.Supervisor

    Enum.each(@needed, fn mod ->
      case Supervisor.start_child(sup, {mod, []}) do
        {:ok, _pid} ->
          :ok

        {:ok, _pid, _info} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          case Supervisor.restart_child(sup, mod) do
            {:ok, _pid} -> :ok
            {:ok, _pid, _info} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            other -> flunk_child(mod, other)
          end

        other ->
          flunk_child(mod, other)
      end
    end)

    true = Arbor.Signals.healthy?()
    :ok
  end

  defp flunk_child(mod, reason) do
    raise "failed to start supervised signals child #{inspect(mod)}: #{inspect(reason)}"
  end
end
