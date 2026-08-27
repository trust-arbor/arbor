defmodule Arbor.Shell.OciUnitCoreTest do
  @moduledoc """
  Pure lifecycle reducer tests for OCI/Podman units.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.OciPlanCore
  alias Arbor.Shell.OciUnitCore, as: Unit

  @moduletag :fast

  @digest String.duplicate("a", 64)
  @image "sha256:#{@digest}"
  @name "arbor-oci-unit1"

  @projections %{
    worktree: "/tmp/arbor-oci/worktree",
    home: "/tmp/arbor-oci/home",
    build: "/tmp/arbor-oci/build",
    deps: "/tmp/arbor-oci/deps",
    validation_runner: "/tmp/arbor-oci/runner",
    validation_result: "/tmp/arbor-oci/result",
    mix_wrapper_dir: "/tmp/arbor-oci/bin"
  }

  @valid_request %{
    image: @image,
    name: @name,
    projections: @projections,
    mix_env: "test",
    command_args: ["test", "apps/arbor_shell/test/example_test.exs"],
    resource_profile: :standard,
    driver: :podman,
    platform: "linux/amd64"
  }

  setup do
    assert {:ok, plan} = OciPlanCore.new(@valid_request)
    {:ok, plan: plan}
  end

  defp success(overrides) do
    Map.merge(
      %{
        exit_code: 0,
        stdout: "",
        stderr: "",
        timed_out: false,
        cancelled: false,
        killed: false,
        output_truncated: false,
        output_limit_exceeded: false
      },
      overrides
    )
  end

  defp success_list(entries), do: success(%{stdout: Jason.encode!(entries)})

  defp through_create_pending(plan) do
    assert {:ok, state, _} = Unit.new(plan)

    assert {:ok, state, _} =
             Unit.apply_result(state, :verify_absent, success_list([]))

    state
  end

  defp through_start_pending(plan) do
    state = through_create_pending(plan)
    assert {:ok, state, _} = Unit.apply_result(state, :create, success(%{exit_code: 0}))
    state
  end

  defp finish_cleanup_absent(state) do
    assert {:ok, state, _} = Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))
    assert {:ok, state, _} = Unit.apply_result(state, :delete, success(%{exit_code: 0}))
    Unit.apply_result(state, :verify_absent, success_list([]))
  end

  describe "construct preflight" do
    test "new/1 emits podman ps list as verify_absent", %{plan: plan} do
      assert {:ok, state, effects} = Unit.new(plan)
      assert state.stage == :preflight
      assert effects == [{:run, :verify_absent, plan.argv.verify_absent}]

      assert plan.argv.verify_absent == [
               "/usr/bin/podman",
               "ps",
               "-a",
               "--format",
               "json"
             ]
    end

    test "requires exact canonical plan equality", %{plan: plan} do
      assert {:ok, _, _} = Unit.new(plan)
      assert {:error, :plan_not_canonical} = Unit.new(Map.put(plan, :extra, true))
    end
  end

  describe "absence classifier" do
    test "classifies absent, present, nonzero, and invalid json", %{plan: plan} do
      assert :absent = Unit.classify_exact_absence(@name, success_list([]))

      assert :absent =
               Unit.classify_exact_absence(
                 @name,
                 success_list([%{"Names" => ["other"], "Id" => "abc"}])
               )

      assert :present =
               Unit.classify_exact_absence(
                 @name,
                 success_list([%{"Names" => [@name], "Id" => "abc123"}])
               )

      assert :present =
               Unit.classify_exact_absence(
                 @name,
                 success_list([%{"Names" => @name, "Id" => "abc123"}])
               )

      assert :present =
               Unit.classify_exact_absence(
                 @name,
                 success_list([%{"Names" => ["other"], "Id" => @name}])
               )

      assert {:error, :list_nonzero_exit} =
               Unit.classify_exact_absence(@name, success(%{exit_code: 1, stdout: "[]"}))

      assert {:error, :list_invalid_json} =
               Unit.classify_exact_absence(@name, success(%{stdout: "not-json"}))

      assert {:error, :list_not_array} =
               Unit.classify_exact_absence(@name, success(%{stdout: "{}"}))

      assert {:ok, state, _} = Unit.new(plan)

      assert {:ok, state, [{:terminal, {:error, :list_nonzero_exit}}]} =
               Unit.apply_result(state, :verify_absent, success(%{exit_code: 1, stdout: "[]"}))

      assert state.stage == :terminal
    end
  end

  describe "cancellation" do
    test "cancel before create terminates cancelled", %{plan: plan} do
      assert {:ok, state, _} = Unit.new(plan)
      assert {:ok, state, [{:terminal, {:error, :preflight_cancelled}}]} = Unit.cancel(state)
      assert state.stage == :terminal
    end

    test "cancel after create enters cleanup without terminal", %{plan: plan} do
      state = through_create_pending(plan)
      assert {:ok, state, effects} = Unit.cancel(state)
      assert state.stage == :cleanup
      assert state.error_reason == :cancelled
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]
      refute Enum.any?(effects, &match?({:terminal, _}, &1))
    end

    test "cleanup-time cancel does not rewrite a start-phase candidate", %{plan: plan} do
      state = through_start_pending(plan)
      stdout = "** (ErlangError) Erlang error: :enoent\n"

      assert {:ok, state, _} =
               Unit.apply_result(state, :start, success(%{exit_code: 1, stdout: stdout}))

      assert state.stage == :cleanup
      assert state.candidate_result.exit_code == 1
      assert state.candidate_result.killed == false
      refute Map.get(state.candidate_result, :cancelled) == true

      assert {:ok, state, effects} = Unit.cancel(state)
      assert state.stage == :cleanup
      assert state.candidate_result.exit_code == 1
      assert state.candidate_result.stdout == stdout
      assert state.candidate_result.killed == false
      refute Map.get(state.candidate_result, :cancelled) == true
      refute Enum.any?(effects, &match?({:terminal, _}, &1))

      assert {:ok, state, [{:terminal, {:ok, result}}]} = finish_cleanup_absent(state)
      assert result.exit_code == 1
      assert result.stdout == stdout
      assert result.killed == false
      refute Map.get(result, :cancelled) == true
      assert state.stage == :terminal
    end

    test "start-phase timeout flags survive cleanup-time cancel", %{plan: plan} do
      state = through_start_pending(plan)

      assert {:ok, state, _} =
               Unit.apply_result(
                 state,
                 :start,
                 success(%{timed_out: true, killed: true, exit_code: 137, stdout: "t"})
               )

      assert {:ok, state, _} = Unit.cancel(state)
      assert {:ok, _state, [{:terminal, {:ok, result}}]} = finish_cleanup_absent(state)
      assert result.exit_code == 137
      assert result.timed_out == true
      assert result.killed == true
    end
  end

  describe "cleanup after create" do
    test "create failure still enters cleanup then terminals after absence", %{plan: plan} do
      state = through_create_pending(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(state, :create, success(%{exit_code: 1}))

      assert state.stage == :cleanup
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]

      assert {:ok, state, [{:terminal, {:error, :create_failed}}]} =
               finish_cleanup_absent(state)

      assert state.stage == :terminal
    end

    test "start success withholds terminal until absence", %{plan: plan} do
      state = through_start_pending(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(state, :start, success(%{exit_code: 0, stdout: "ok"}))

      assert state.stage == :cleanup
      refute Enum.any?(effects, &match?({:terminal, _}, &1))

      assert {:ok, state, [{:terminal, {:ok, result}}]} = finish_cleanup_absent(state)
      assert result.stdout == "ok"
      assert state.stage == :terminal
    end
  end
end
