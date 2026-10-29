defmodule Arbor.Common.SupervisedOwner do
  @moduledoc false

  @default_timeout 1_000

  @spec registered_child_pid(atom(), [term()], atom(), timeout()) ::
          {:ok, pid()} | {:error, :not_supervised_owner}
  def registered_child_pid(application, child_path, registered_name, timeout \\ @default_timeout),
    do:
      Arbor.Custody.supervised_registered_child_pid(
        application,
        child_path,
        registered_name,
        timeout
      )

  @doc "Binds a startup candidate to its application root; callers still verify the child path."
  @spec starting_application_root(atom(), pid(), pos_integer()) :: {:ok, pid()} | :error
  def starting_application_root(application, candidate, depth),
    do: Arbor.Custody.starting_application_root(application, candidate, depth)
end
