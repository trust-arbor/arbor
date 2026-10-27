defmodule Arbor.Signals.TestSupport.Case do
  @moduledoc """
  Starts package-owned fixtures under their real Signals supervisor.

  A missing supervisor or rejected child is an error. This helper never masks
  ownership failures by starting registered services outside their supervisor.
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      setup do
        Arbor.Signals.TestSupport.Case.ensure_processes()
        :ok
      end
    end
  end

  @spec ensure_processes() :: :ok
  def ensure_processes do
    {:ok, _apps} = Application.ensure_all_started(:arbor_signals)
    :ok = Arbor.Signals.restore_runtime_fixture()
    :ok = Arbor.Signals.Bus.reset()
    :ok
  end
end
