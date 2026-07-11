defmodule Arbor.Orchestrator.ActionsExecutorSchemaWorkdirInjectionTest do
  @moduledoc """
  Public-boundary regressions for schema-aware cwd/workdir injection.

  ActionsExecutor must inject directory context keys only when the selected
  action's Jido schema declares them. Unconditional injection breaks strict
  schema-bounded actions (CrossApp.Validate, SecurityRegression.Validate)
  with :unsupported_parameter before any validation command runs.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.ActionsExecutor

  setup do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
    end)

    workdir = File.cwd!()
    explicit_dir = Path.join(System.tmp_dir!(), "arbor_schema_workdir_explicit")
    File.mkdir_p!(explicit_dir)

    on_exit(fn -> File.rmdir(explicit_dir) end)

    %{workdir: workdir, explicit_dir: explicit_dir}
  end

  describe "schema-aware workdir/cwd injection" do
    test "strict CrossApp.Validate (neither key) receives neither injected key", %{
      workdir: workdir
    } do
      {module, params} =
        capture_invocation(
          "coding_cross_app_validate",
          %{"workspace_id" => "ws_test"},
          workdir
        )

      assert module == Arbor.Actions.Coding.CrossApp.Validate

      assert Map.get(params, :workspace_id) == "ws_test" or
               Map.get(params, "workspace_id") == "ws_test"

      refute Map.has_key?(params, :workdir)
      refute Map.has_key?(params, "workdir")
      refute Map.has_key?(params, :cwd)
      refute Map.has_key?(params, "cwd")
    end

    test "strict SecurityRegression.Validate (neither key) receives neither injected key", %{
      workdir: workdir
    } do
      {module, params} =
        capture_invocation(
          "coding_security_regression_validate",
          %{"review_attestation_id" => "att_test"},
          workdir
        )

      assert module == Arbor.Actions.Coding.SecurityRegression.Validate

      assert Map.get(params, :review_attestation_id) == "att_test" or
               Map.get(params, "review_attestation_id") == "att_test"

      refute Map.has_key?(params, :workdir)
      refute Map.has_key?(params, "workdir")
      refute Map.has_key?(params, :cwd)
      refute Map.has_key?(params, "cwd")
    end

    test "shell_execute (declares cwd) receives cwd but not workdir", %{workdir: workdir} do
      {module, params} =
        capture_invocation("shell_execute", %{"command" => "true"}, workdir)

      assert module == Arbor.Actions.Shell.Execute
      assert Map.get(params, :cwd) == workdir or Map.get(params, "cwd") == workdir
      refute Map.has_key?(params, :workdir)
      refute Map.has_key?(params, "workdir")
    end

    test "apply_changes (declares workdir) receives workdir but not cwd", %{workdir: workdir} do
      {module, params} =
        capture_invocation(
          "apply_changes",
          %{"changes_json" => ~s({"changes":[]})},
          workdir
        )

      assert module == Arbor.Actions.CodeReview.ApplyChanges
      assert Map.get(params, :workdir) == workdir or Map.get(params, "workdir") == workdir
      refute Map.has_key?(params, :cwd)
      refute Map.has_key?(params, "cwd")
    end

    test "explicitly supplied schema-supported cwd is not overwritten", %{
      workdir: workdir,
      explicit_dir: explicit_dir
    } do
      {module, params} =
        capture_invocation(
          "shell_execute",
          %{"command" => "true", "cwd" => explicit_dir},
          workdir
        )

      assert module == Arbor.Actions.Shell.Execute
      assert Map.get(params, :cwd) == explicit_dir or Map.get(params, "cwd") == explicit_dir
      refute Map.get(params, :cwd) == workdir
      refute Map.get(params, "cwd") == workdir
      refute Map.has_key?(params, :workdir)
      refute Map.has_key?(params, "workdir")
    end

    test "explicitly supplied schema-supported workdir is not overwritten", %{
      workdir: workdir,
      explicit_dir: explicit_dir
    } do
      {module, params} =
        capture_invocation(
          "apply_changes",
          %{"changes_json" => ~s({"changes":[]}), "workdir" => explicit_dir},
          workdir
        )

      assert module == Arbor.Actions.CodeReview.ApplyChanges

      assert Map.get(params, :workdir) == explicit_dir or
               Map.get(params, "workdir") == explicit_dir

      refute Map.get(params, :workdir) == workdir
      refute Map.get(params, "workdir") == workdir
      refute Map.has_key?(params, :cwd)
      refute Map.has_key?(params, "cwd")
    end

    test "explicit unknown caller keys are preserved (not dropped by injection)", %{
      workdir: workdir
    } do
      {module, params} =
        capture_invocation(
          "coding_cross_app_validate",
          %{"workspace_id" => "ws_test", "extra_caller_field" => "kept"},
          workdir
        )

      assert module == Arbor.Actions.Coding.CrossApp.Validate

      # Unknown keys stay as provided (string keys not in schema are not atomized)
      assert Map.get(params, "extra_caller_field") == "kept" or
               Map.get(params, :extra_caller_field) == "kept"

      refute Map.has_key?(params, :workdir)
      refute Map.has_key?(params, :cwd)
    end
  end

  defp capture_invocation(action_name, args, workdir) do
    tracer = self()

    task =
      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])
        ActionsExecutor.execute(action_name, args, workdir)
      end)

    result = Task.await(task, 15_000)

    receive do
      {:trace, _pid, :call,
       {Arbor.Actions, :authorize_and_execute, [_agent_id, module, params, _context]}} ->
        {module, params}
    after
      5_000 ->
        flunk("""
        expected authorize_and_execute trace for #{action_name}
        execute result: #{inspect(result)}
        """)
    end
  end
end
