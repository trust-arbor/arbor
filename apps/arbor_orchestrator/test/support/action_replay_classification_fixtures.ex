defmodule Arbor.Actions.TestFixtures.ReplayReadOnlyAction do
  @moduledoc false

  use Jido.Action,
    name: "test_replay_read_only",
    description: "Read-only replay classification fixture",
    schema: []

  def execution_idempotency do
    notify(:replay_read_only_classified)
    :read_only
  end

  @impl true
  def run(_params, _context) do
    notify(:replay_read_only_action_executed)
    {:ok, %{fixture: :read_only}}
  end

  defp notify(message) do
    if pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid) do
      send(pid, message)
    end
  end
end

defmodule Arbor.Actions.TestFixtures.ReplayDefaultAction do
  @moduledoc false

  use Jido.Action,
    name: "test_replay_default",
    description: "Default replay classification fixture",
    schema: []

  @impl true
  def run(_params, _context) do
    notify(:replay_default_action_executed)
    {:ok, %{fixture: :default}}
  end

  defp notify(message) do
    if pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid) do
      send(pid, message)
    end
  end
end

defmodule Arbor.Actions.TestFixtures.ReplayContradictoryWriteAction do
  @moduledoc false

  use Jido.Action,
    name: "test_replay_contradictory_write",
    description: "Contradictory replay classification fixture",
    schema: []

  def effect_class, do: :local_write
  def execution_idempotency, do: :read_only

  @impl true
  def run(_params, _context) do
    notify(:replay_contradictory_write_executed)
    {:ok, %{fixture: :contradictory_write}}
  end

  defp notify(message) do
    if pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid) do
      send(pid, message)
    end
  end
end

defmodule Arbor.Actions.TestFixtures.ReplayDriftOriginalAction do
  @moduledoc false

  use Jido.Action,
    name: "test_replay_drift",
    description: "Original replay classification drift fixture",
    schema: []

  def execution_idempotency do
    case Application.get_env(:arbor_orchestrator, :action_replay_drift_hook) do
      hook when is_function(hook, 0) -> hook.()
      _other -> :ok
    end

    :read_only
  end

  @impl true
  def run(_params, _context) do
    notify(:replay_drift_original_executed)
    {:ok, %{fixture: :drift_original}}
  end

  defp notify(message) do
    if pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid) do
      send(pid, message)
    end
  end
end

defmodule Arbor.Actions.TestFixtures.ReplayDriftReplacementAction do
  @moduledoc false

  use Jido.Action,
    name: "test_replay_drift",
    description: "Replacement replay classification drift fixture",
    schema: []

  def execution_idempotency, do: :read_only

  @impl true
  def run(_params, _context) do
    notify(:replay_drift_replacement_executed)
    {:ok, %{fixture: :drift_replacement}}
  end

  defp notify(message) do
    if pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid) do
      send(pid, message)
    end
  end
end

defmodule Arbor.Orchestrator.TestFixtures.ReplayActionsExecutor do
  @moduledoc false

  def execute(name, _args, _workdir, opts) do
    if pid = Application.get_env(:arbor_orchestrator, :action_replay_test_pid) do
      send(pid, {:replay_executor_called, name, Keyword.get(opts, :execution_id)})
    end

    {:ok, %{fixture: name}}
  end
end
