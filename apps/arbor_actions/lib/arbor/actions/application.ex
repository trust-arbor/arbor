defmodule Arbor.Actions.Application do
  @moduledoc """
  Application supervisor for Arbor.Actions.

  Arbor.Actions provides Jido-compatible action modules for common operations
  like shell commands, file operations, and git operations.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for tracking action executions if needed
      {Registry, keys: :unique, name: Arbor.Actions.Registry}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Actions.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
