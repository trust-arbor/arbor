defmodule Arbor.Actions.SecurityRegression.MessageToolTaint do
  @moduledoc false

  use Jido.Action,
    name: "security_regression_message_tool_taint",
    description: "Records a bounded marker when a model-controlled command executes",
    schema: [
      command: [type: :string, required: true]
    ]

  @parent_key {__MODULE__, :test_parent}

  def set_test_parent(pid) when is_pid(pid), do: :persistent_term.put(@parent_key, pid)
  def clear_test_parent, do: :persistent_term.erase(@parent_key)

  def taint_roles, do: %{command: :control}
  def effect_class, do: :read
  def execution_idempotency, do: :read_only

  @impl true
  def run(params, _context) do
    command = Map.get(params, :command) || Map.get(params, "command")

    case :persistent_term.get(@parent_key, nil) do
      pid when is_pid(pid) -> send(pid, {:message_tool_taint_action_executed, command})
      _ -> :ok
    end

    {:ok, %{observed: command}}
  end
end
