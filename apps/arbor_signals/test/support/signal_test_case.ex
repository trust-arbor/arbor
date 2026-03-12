defmodule Arbor.Signals.TestCase do
  @moduledoc """
  Shared setup for signal tests that need GenServer processes running.

  Ensures the arbor_signals application is started and all required
  GenServer processes are running. Handles umbrella test context where
  the application supervisor may not be available.
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      setup do
        Arbor.Signals.TestCase.ensure_processes()
        :ok
      end
    end
  end

  @doc "Ensure all signal GenServer processes are running."
  def ensure_processes do
    # First ensure the application and its supervisor are running
    Application.ensure_all_started(:arbor_signals)

    children = [
      Arbor.Signals.Store,
      Arbor.Signals.TopicKeys,
      Arbor.Signals.Channels,
      Arbor.Signals.Bus,
      Arbor.Signals.Relay
    ]

    for mod <- children do
      ensure_child(mod)
    end

    # Reset Bus state to prevent subscription leakage between test files
    if Process.whereis(Arbor.Signals.Bus) do
      Arbor.Signals.Bus.reset()
    end
  end

  defp ensure_child(mod) do
    case Process.whereis(mod) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: start_child(mod)

      nil ->
        start_child(mod)
    end
  end

  defp start_child(mod) do
    child_spec = {mod, []}

    if Process.whereis(Arbor.Signals.Supervisor) do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child_spec) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          Supervisor.delete_child(Arbor.Signals.Supervisor, mod)
          Supervisor.start_child(Arbor.Signals.Supervisor, child_spec)

        {:error, _reason} ->
          # Supervisor rejected it — start standalone
          mod.start_link([])
      end
    else
      # No supervisor available — start standalone
      mod.start_link([])
    end
  rescue
    _ -> mod.start_link([])
  end
end
