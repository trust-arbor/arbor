defmodule Arbor.Voice.Test.SettlementFakeLedger do
  @moduledoc """
  Deterministic, network-free ledger fake for `Arbor.Voice.Session.Settlement`
  tests — implements the same `consume/3` / `release/2` contract as
  `Arbor.Voice.BudgetLedger` without touching persistence.

  Call history is recorded in an `Agent` started by the test (owned by the
  ExUnit process), so evidence survives a killed calling `Task`. `:pause_once`
  mode lets a test observe "durably accepted" (the call is recorded) before
  the fake blocks forever — the test then kills the calling process at that
  exact point and asserts a replay reaches `:done` without a second charge.
  """

  use Agent

  defstruct calls: [], mode: :ok

  @type mode :: :ok | :error | {:pause_once, pid()}

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Agent.start_link(fn -> %__MODULE__{} end, name: name)
  end

  @spec stop(atom()) :: :ok
  def stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  @doc "Set the outcome of the next call(s) that haven't yet been recorded."
  @spec set_mode(atom(), mode()) :: :ok
  def set_mode(name, mode), do: Agent.update(name, &%{&1 | mode: mode})

  @doc "Recorded calls in order: {:consume, reservation_id, elapsed_ms} | {:release, reservation_id}."
  @spec calls(atom()) :: [tuple()]
  def calls(name), do: Agent.get(name, &Enum.reverse(&1.calls))

  def consume(reservation, elapsed_ms, opts) do
    name = Keyword.fetch!(opts, :name)
    handle(name, {:consume, reservation.id, elapsed_ms})
  end

  def release(reservation, opts) do
    name = Keyword.fetch!(opts, :name)
    handle(name, {:release, reservation.id})
  end

  defp handle(name, call) do
    mode =
      Agent.get_and_update(name, fn state ->
        {state.mode, %{state | calls: [call | state.calls]}}
      end)

    case mode do
      :ok ->
        :ok

      :error ->
        {:error, :backend_error}

      {:pause_once, notify_pid} ->
        Agent.update(name, &%{&1 | mode: :ok})
        send(notify_pid, {:accepted, self(), call})
        Process.sleep(:infinity)
    end
  end
end
