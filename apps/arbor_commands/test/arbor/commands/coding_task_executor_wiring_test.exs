defmodule Arbor.Commands.CodingTaskExecutorWiringTest do
  @moduledoc """
  Integration assertion for the root production task_executors mapping.

  Lives in arbor_commands because that library legitimately depends on both
  arbor_agent and arbor_orchestrator. The Level-7 boundary forbids arbor_agent
  from hardcoding Arbor.Orchestrator.CodingTaskExecutor.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Config, as: AgentConfig
  alias Arbor.Orchestrator.CodingTaskExecutor

  test "root config maps coding_change to CodingTaskExecutor" do
    assert AgentConfig.task_executors()["coding_change"] == CodingTaskExecutor

    assert {:ok, CodingTaskExecutor} = AgentConfig.task_executor("coding_change")
    assert {:ok, CodingTaskExecutor} = AgentConfig.task_executor(:coding_change)
    assert function_exported?(CodingTaskExecutor, :run, 3)
    assert function_exported?(CodingTaskExecutor, :task_status, 2)
    assert function_exported?(CodingTaskExecutor, :cancel_task, 2)
    assert function_exported?(CodingTaskExecutor, :finalize_terminal_task, 4)
  end
end
