defmodule Arbor.Actions.Test.NativeResourceProbe do
  use Jido.Action,
    name: "native_resource_probe",
    description: "Provider-free parameterized resource regression probe",
    schema: [target: [type: :string, required: true], mode: [type: :string, required: true]]

  def effect_class, do: :local_write
  def taint_roles, do: %{target: :control, mode: :control}

  def authorization_resource(%{target: target, mode: "valid"}),
    do: {:ok, "arbor://action/test/native_resource_probe/" <> target}

  def authorization_resource(%{mode: "error"}), do: {:error, :probe_resource_refused}
  def authorization_resource(%{mode: "malformed"}), do: {:ok, %{resource: "arbor://action/test"}}

  def authorization_resource(%{mode: "oversized"}),
    do: {:ok, "arbor://action/test/" <> String.duplicate("a", 4_096)}

  @impl true
  def run(params, _context) do
    send(:native_resource_probe_observer, {:native_resource_probe_ran, params})
    {:ok, %{target: params.target}}
  end
end

defmodule Arbor.Actions.Test.NativeResourceFacadeProbe do
  use Jido.Action,
    name: "native_resource_facade_probe",
    description: "Explicit mandatory Actions facade admission probe",
    schema: [target: [type: :string, required: true], mode: [type: :string, required: true]]

  def effect_class, do: :local_write
  def taint_roles, do: %{target: :control, mode: :control}
  def authorization_admission_owner, do: :actions_facade
  defdelegate authorization_resource(params), to: Arbor.Actions.Test.NativeResourceProbe
  @impl true
  defdelegate run(params, context), to: Arbor.Actions.Test.NativeResourceProbe
end

defmodule Arbor.Actions.Test.NativeResourceMalformedOwnerProbe do
  use Jido.Action,
    name: "native_resource_malformed_owner_probe",
    description: "Malformed admission-owner declaration must fail closed",
    schema: [target: [type: :string, required: true], mode: [type: :string, required: true]]

  def effect_class, do: :local_write
  def authorization_admission_owner, do: :self
  defdelegate authorization_resource(params), to: Arbor.Actions.Test.NativeResourceProbe
  @impl true
  defdelegate run(params, context), to: Arbor.Actions.Test.NativeResourceProbe
end

defmodule Arbor.Orchestrator.Test.NativeResourceCustomExecHandler do
  @behaviour Arbor.Orchestrator.Handlers.Handler
  @impl true
  def idempotency, do: :read_only
  @impl true
  def execute(_node, _context, _graph, _opts) do
    send(:native_resource_probe_observer, :custom_facade_handler_effect)
    %Arbor.Orchestrator.Engine.Outcome{status: :success}
  end
end

defmodule Arbor.Orchestrator.Test.NativeResourceCustomActionsExecutor do
  def execute(_name, _args, _workdir, _opts) do
    send(:native_resource_probe_observer, :custom_facade_executor_effect)
    {:ok, %{executed: true}}
  end
end
