defmodule Arbor.Voice.CleanupLeaseSupervisor do
  @moduledoc """
  Holds cleanup-only owners independently of Voice sessions and resource owners.

  The application starts this supervisor before the resource/session supervisors
  so reverse-order shutdown leaves cleanup ownership available while those
  processes terminate.
  """

  @name __MODULE__
  @max_children 256

  @doc false
  def child_spec(_args) do
    %{
      id: @name,
      start:
        {DynamicSupervisor, :start_link,
         [
           [
             name: @name,
             strategy: :one_for_one,
             max_children: @max_children,
             max_restarts: 100,
             max_seconds: 1
           ]
         ]},
      type: :supervisor
    }
  end
end
