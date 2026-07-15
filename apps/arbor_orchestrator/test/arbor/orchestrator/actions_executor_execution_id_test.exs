defmodule Arbor.Orchestrator.ActionsExecutorExecutionIdTest do
  @moduledoc """
  L3B B3: ActionsExecutor places the owner-issued effect execution_id into the
  action context passed to Arbor.Actions.authorize_and_execute/4 only when the
  process-local opts key is present. Direct execution without an owner ID omits
  the key. The ID is never copied into params.
  """
  use ExUnit.Case, async: false
  @moduletag :fast
  @owner_id "exec_" <> String.duplicate("a", 32)

  alias Arbor.Orchestrator.ActionsExecutor

  setup do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
    end)

    :ok
  end

  test "forwards the exact execution_id into authorize_and_execute context" do
    {_module, params, context} =
      capture_invocation("file.read", %{"path" => "mix.exs"}, ".", execution_id: @owner_id)

    assert Map.fetch!(context, :execution_id) === @owner_id
    refute Map.has_key?(params, :execution_id)
    refute Map.has_key?(params, "execution_id")
  end

  test "omits execution_id from action context when owner ID is absent" do
    {_module, params, context} = capture_invocation("file.read", %{"path" => "mix.exs"}, ".")

    refute Map.has_key?(context, :execution_id)
    refute Map.has_key?(context, "execution_id")
    refute Map.has_key?(params, :execution_id)
    refute Map.has_key?(params, "execution_id")
  end

  test "does not promote an action param named execution_id into context" do
    # Params are action input; only process-local opts supply the owner ID.
    {_module, params, context} =
      capture_invocation(
        "file.read",
        %{"path" => "mix.exs", "execution_id" => "param_spoof"},
        "."
      )

    refute Map.has_key?(context, :execution_id)
    refute Map.has_key?(context, "execution_id")

    assert params["execution_id"] === "param_spoof"
    refute params["execution_id"] === @owner_id
  end

  defp capture_invocation(action_name, args, workdir, opts \\ []) do
    tracer = self()

    task =
      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])
        ActionsExecutor.execute(action_name, args, workdir, opts)
      end)

    result = Task.await(task, 15_000)

    receive do
      {:trace, _pid, :call,
       {Arbor.Actions, :authorize_and_execute, [_agent_id, module, params, context]}} ->
        {module, params, context}
    after
      5_000 ->
        flunk("""
        expected authorize_and_execute trace for #{action_name}
        execute result: #{inspect(result)}
        """)
    end
  end
end
