defmodule Arbor.Actions.TestFixtures.BoundNestedInnerAction do
  @moduledoc false

  use Jido.Action,
    name: "bound_nested_inner_action",
    description: "Inner action used to verify nested execution binding",
    schema: []

  @impl true
  def run(_params, context) do
    if pid = Map.get(context, :test_pid), do: send(pid, :bound_nested_inner_executed)
    {:ok, %{inner: true}}
  end
end

defmodule Arbor.Actions.TestFixtures.BoundNestedOtherAction do
  @moduledoc false

  use Jido.Action,
    name: "bound_nested_other_action",
    description: "Second inner action used to verify parallel execution binding",
    schema: []

  @impl true
  def run(_params, context) do
    if pid = Map.get(context, :test_pid), do: send(pid, :bound_nested_other_executed)
    {:ok, %{other: true}}
  end
end

defmodule Arbor.Actions.TestFixtures.BoundCompositeAction do
  @moduledoc false

  use Jido.Action,
    name: "bound_composite_action",
    description: "Composite action used to verify nested execution binding",
    schema: []

  @impl true
  def run(params, context) do
    nested_context = if Map.get(params, :strip_context, true), do: %{}, else: context

    Arbor.Actions.authorize_and_execute(
      Map.get(context, :agent_id, "system"),
      Arbor.Actions.TestFixtures.BoundNestedInnerAction,
      %{},
      nested_context
    )
  end
end

defmodule Arbor.Actions.TestFixtures.BoundParallelCompositeAction do
  @moduledoc false

  use Jido.Action,
    name: "bound_parallel_composite_action",
    description: "Composite action used to verify parallel nested execution binding",
    schema: []

  @impl true
  def run(_params, context) do
    modules = [
      Arbor.Actions.TestFixtures.BoundNestedInnerAction,
      Arbor.Actions.TestFixtures.BoundNestedOtherAction
    ]

    results =
      modules
      |> Task.async_stream(
        fn module ->
          Arbor.Actions.authorize_and_execute(
            Map.get(context, :agent_id, "system"),
            module,
            %{},
            context
          )
        end,
        ordered: true,
        timeout: 1_000
      )
      |> Enum.to_list()

    {:ok, %{results: results}}
  end
end

defmodule Arbor.Actions.TestFixtures.BoundStrippedTaskCompositeAction do
  @moduledoc false

  use Jido.Action,
    name: "bound_stripped_task_composite_action",
    description: "Composite action used to verify task caller binding inheritance",
    schema: []

  @impl true
  def run(_params, context) do
    Task.async(fn ->
      Arbor.Actions.authorize_and_execute(
        Map.get(context, :agent_id, "system"),
        Arbor.Actions.TestFixtures.BoundNestedInnerAction,
        %{},
        %{}
      )
    end)
    |> Task.await(1_000)
  end
end

defmodule Arbor.Actions.TestFixtures.BoundLineageCompositeAction do
  @moduledoc false

  use Jido.Action,
    name: "bound_lineage_composite_action",
    description: "Composite action used to verify nested Engine binding lineage",
    schema: []

  @impl true
  def run(_params, context) do
    nested_context = Map.fetch!(context, :nested_execution_binding_context)
    nested_action = Map.fetch!(context, :nested_action_module)

    invoke = fn ->
      Arbor.Actions.execute_action(nested_action, %{}, nested_context)
    end

    if Map.get(context, :nested_in_task, false) do
      invoke
      |> Task.async()
      |> Task.await(1_000)
    else
      invoke.()
    end
  end
end

defmodule Arbor.Actions.TestFixtures.BoundBatchCompositeAction do
  @moduledoc false

  use Jido.Action,
    name: "bound_batch_composite_action",
    description: "Composite action used to verify execute_batch binding inheritance",
    schema: []

  @impl true
  def run(_params, _context) do
    [{_spec, result}] =
      Arbor.Actions.execute_batch(
        [%{"type" => "session_classify", "params" => %{"input" => "nested"}}],
        agent_id: "system"
      )

    result
  end
end
