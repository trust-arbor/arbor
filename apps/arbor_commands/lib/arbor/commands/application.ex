defmodule Arbor.Commands.Application do
  @moduledoc false

  use Application

  @command_modules [
    Arbor.Commands.Runtime,
    Arbor.Commands.Model,
    Arbor.Commands.Start
  ]

  @impl true
  def start(_type, _args) do
    # Force-load the command modules so `Arbor.Common.CommandRouter`'s
    # `:code.all_loaded()` discovery scan picks them up regardless of
    # whether any other module has referenced them yet. Without this,
    # the first user typing `/runtime acp` might not see the command
    # registered if no other code has touched the module.
    Enum.each(@command_modules, &Code.ensure_loaded/1)

    # Best-effort refresh — if CommandRouter isn't started yet, the
    # refresh will be a no-op (its persistent_term cache is populated
    # on first call_).
    if Code.ensure_loaded?(Arbor.Common.CommandRouter) and
         function_exported?(Arbor.Common.CommandRouter, :refresh, 0) do
      try do
        Arbor.Common.CommandRouter.refresh()
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
  end
end
