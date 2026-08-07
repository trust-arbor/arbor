defmodule Arbor.Memory.MutationAdmission.GuardianSupervisor do
  @moduledoc """
  Sibling DynamicSupervisor for per-root-lease guardians.

  Survives `MutationAdmission` restarts so local monitors remain blockers.
  """

  @name __MODULE__
  @max_children 4096

  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @name)

    %{
      id: name,
      start:
        {DynamicSupervisor, :start_link,
         [
           [
             name: name,
             strategy: :one_for_one,
             max_children: @max_children,
             max_restarts: 100,
             max_seconds: 1
           ]
         ]},
      type: :supervisor
    }
  end

  @doc false
  def name, do: @name
end
