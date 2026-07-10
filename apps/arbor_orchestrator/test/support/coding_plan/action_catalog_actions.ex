defmodule Arbor.Actions.TestFixtures.AlphaAction do
  @moduledoc false

  def to_tool do
    %{
      name: "alpha_action",
      description: "Alpha action",
      function: fn _params, _context -> {:ok, "ignored"} end,
      module: __MODULE__,
      owner: self(),
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "count" => %{"minimum" => 0, "type" => "integer"},
          "label" => %{"type" => "string"}
        },
        "required" => ["label"]
      }
    }
  end
end

defmodule Arbor.Actions.TestFixtures.ZebraAction do
  @moduledoc false

  def to_tool do
    %{
      "parameters_schema" => %{
        properties: %{
          enabled: %{"type" => "boolean"}
        },
        type: "object"
      },
      "description" => "Zebra action",
      "name" => "zebra_action"
    }
  end
end

defmodule Arbor.Actions.TestFixtures.AlphaSchemaChangedAction do
  @moduledoc false

  def to_tool do
    %{
      name: "alpha_action",
      description: "Alpha action",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "count" => %{"minimum" => 1, "type" => "integer"},
          "label" => %{"type" => "string"}
        },
        "required" => ["label"]
      }
    }
  end
end

defmodule Arbor.Actions.TestFixtures.MissingDescriptionAction do
  @moduledoc false
  def to_tool, do: %{name: "missing_description", parameters_schema: %{"type" => "object"}}
end

defmodule Arbor.Actions.TestFixtures.InvalidSchemaAction do
  @moduledoc false

  def to_tool do
    %{
      name: "invalid_schema",
      description: "Invalid schema",
      parameters_schema: %{"properties" => %{"callback" => fn -> :ok end}}
    }
  end
end

defmodule Arbor.Actions.TestFixtures.RaisingAction do
  @moduledoc false
  def to_tool, do: raise("cannot inspect action")
end

defmodule Arbor.Actions.TestFixtures.LongErrorAction do
  @moduledoc false
  def to_tool, do: raise(String.duplicate("oversized error ", 100))
end

defmodule Arbor.Actions.TestFixtures.InvalidUtf8NameAction do
  @moduledoc false

  def to_tool do
    %{
      name: <<"invalid_name_", 0xFF>>,
      description: "Invalid UTF-8 name",
      parameters_schema: %{"type" => "object"}
    }
  end
end

defmodule Arbor.Actions.TestFixtures.InvalidUtf8DescriptionAction do
  @moduledoc false

  def to_tool do
    %{
      name: "invalid_utf8_description",
      description: <<"invalid description ", 0xFF>>,
      parameters_schema: %{"type" => "object"}
    }
  end
end

defmodule Arbor.Actions.TestFixtures.BindingOriginalAction do
  @moduledoc false

  def to_tool do
    %{
      name: "binding_action",
      description: "Binding fixture",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}}
      }
    }
  end
end

defmodule Arbor.Actions.TestFixtures.BindingReplacementAction do
  @moduledoc false

  def to_tool do
    %{
      name: "binding_action",
      description: "Binding fixture",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}}
      }
    }
  end

  def effect_class, do: :local_write
end

defmodule Arbor.Actions.TestFixtures.BindingSchemaChangedAction do
  @moduledoc false

  def to_tool do
    %{
      name: "binding_action",
      description: "Binding fixture",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}}
      }
    }
  end
end

defmodule Arbor.Actions.TestFixtures.UnrelatedBindingAction do
  @moduledoc false

  def to_tool do
    %{
      name: "unrelated_binding_action",
      description: "Unreferenced fixture",
      parameters_schema: %{"type" => "object", "properties" => %{}}
    }
  end
end

defmodule Arbor.Actions.TestFixtures.SessionClassifyReplacementAction do
  @moduledoc false

  use Jido.Action,
    name: "session_classify",
    description: "Classify session input as query, command, tool_result, or blocked",
    schema: [
      input: [type: :string, required: false, doc: "Input to classify"],
      blocked: [type: :boolean, required: false, doc: "Whether session is blocked"]
    ]

  @impl true
  def run(_params, _context) do
    case Application.get_env(:arbor_orchestrator, :phase5_action_binding_test_pid) do
      pid when is_pid(pid) -> send(pid, :replacement_action_executed)
      _other -> :ok
    end

    {:ok, %{input_type: "replacement"}}
  end
end

defmodule Arbor.Orchestrator.TestHandlers.AlternateExec do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def execute(_node, _context, _graph, _opts), do: %Outcome{status: :success}

  @impl true
  def idempotency, do: :side_effecting
end

defmodule Arbor.Orchestrator.TestHandlers.AlternateComputeDelegate do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def execute(_node, _context, _graph, _opts) do
    notify(:alternate_compute_delegate_executed)
    %Outcome{status: :success}
  end

  @impl true
  def idempotency, do: :read_only

  defp notify(message) do
    if pid = Application.get_env(:arbor_orchestrator, :phase5_delegate_binding_test_pid) do
      send(pid, message)
    end
  end
end

defmodule Arbor.Orchestrator.TestHandlers.AlternateComposeDelegate do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def execute(_node, _context, _graph, _opts) do
    notify(:alternate_compose_delegate_executed)
    %Outcome{status: :success}
  end

  @impl true
  def idempotency, do: :side_effecting

  defp notify(message) do
    if pid = Application.get_env(:arbor_orchestrator, :phase5_delegate_binding_test_pid) do
      send(pid, message)
    end
  end
end

defmodule Arbor.Orchestrator.TestHandlers.AlternateActionsExecutor do
  @moduledoc false

  def execute(_action_name, _args, _workdir, _opts) do
    if pid = Application.get_env(:arbor_orchestrator, :phase5_delegate_binding_test_pid) do
      send(pid, :alternate_actions_executor_executed)
    end

    {:ok, %{executed: true}}
  end
end
