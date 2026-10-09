defmodule Arbor.Commands.Test.AgentAuthorityTopology do
  @moduledoc false

  # Commands tests run in their own BEAM. `config/test.exs` leaves the agent
  # supervisor empty, so recovery authority and operator verification have no
  # ProfileAuthorityOwner or application TaskStore unless this starts them.
  # The handoff fixture still has to be issued by that supervised TaskStore.

  alias Arbor.Agent.Orchestration.TaskStore

  @recovery_purpose :coding_task_recovery

  def ensure_owned! do
    {:ok, _} = Application.ensure_all_started(:arbor_agent)

    :ok = start_child({Task.Supervisor, name: Arbor.Agent.Orchestration.TaskSupervisor})
    :ok = start_child(Arbor.Agent.ProfileAuthorityOwner)
    :ok = start_child(TaskStore)
    :ok
  end

  def authorize_recovery!(principal, task_id, caller_id)
      when is_binary(principal) and is_binary(task_id) and is_binary(caller_id) do
    context = %{
      operation: :recover,
      task_id: task_id,
      control_principal_id: caller_id,
      task_digest: String.duplicate("b", 64)
    }

    TaskStore.authorize_signing_authority_handoff_fixture(
      principal,
      @recovery_purpose,
      self(),
      context
    )
  end

  defp start_child(child) do
    case Supervisor.start_child(Arbor.Agent.AppSupervisor, child) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :already_present} ->
        case Supervisor.restart_child(Arbor.Agent.AppSupervisor, child_id(child)) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> {:error, other}
        end

      other ->
        {:error, other}
    end
  end

  defp child_id({Task.Supervisor, _opts}), do: Task.Supervisor
  defp child_id(module) when is_atom(module), do: module
end
