defmodule Arbor.Shell.AppleContainerUnitCoreTest do
  @moduledoc """
  Pure lifecycle reducer tests for Apple Container units.

  No process execution — command results are injected as plain maps.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerPlanCore
  alias Arbor.Shell.AppleContainerUnitCore, as: Unit

  @moduletag :fast

  @index_hex String.duplicate("a", 64)
  @vminit_hex String.duplicate("b", 64)
  @image "127.0.0.1:0/arbor/workload@sha256:#{@index_hex}"
  @init_image "127.0.0.1:0/arbor/vminit@sha256:#{@vminit_hex}"
  @kernel_path "/usr/local/share/container/kernels/default.kernel"
  @name "arbor-val-unit1"

  @projections %{
    worktree: "/private/tmp/arbor-val/worktree",
    home: "/private/tmp/arbor-val/home",
    tmp: "/private/tmp/arbor-val/tmp",
    build: "/private/tmp/arbor-val/build",
    deps: "/private/tmp/arbor-val/deps",
    runtime: "/private/tmp/arbor-val/runtime",
    mix_wrapper: "/private/tmp/arbor-val/bin/mix"
  }

  @host_runtime_roots %{
    erlang: "/opt/erlang",
    elixir: "/opt/elixir"
  }

  @valid_request %{
    image: @image,
    init_image: @init_image,
    kernel_path: @kernel_path,
    name: @name,
    projections: @projections,
    host_runtime_roots: @host_runtime_roots,
    mix_env: "test",
    command_args: ["test", "apps/arbor_shell/test/example_test.exs"]
  }

  setup do
    assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
    {:ok, plan: plan}
  end

  describe "construct preflight" do
    test "new/1 emits exact verify_absent list effect", %{plan: plan} do
      assert {:ok, state, effects} = Unit.new(plan)
      assert state.stage == :preflight
      assert state.create_attempted == false
      assert effects == [{:run, :verify_absent, plan.argv.verify_absent}]

      assert plan.argv.verify_absent == [
               "/usr/local/bin/container",
               "list",
               "--all",
               "--format",
               "json"
             ]
    end

    test "is deterministic for the same plan", %{plan: plan} do
      assert {:ok, a, ea} = Unit.new(plan)
      assert {:ok, b, eb} = Unit.new(plan)
      assert a == b
      assert ea == eb
      assert Unit.show(a) == Unit.show(b)
      assert Jason.encode!(Unit.show(a))
    end

    test "rejects invalid plan" do
      assert {:error, _} = Unit.new(%{})
      assert {:error, :invalid_plan} = Unit.new("nope")
    end
  end

  describe "preflight effects" do
    test "absent list advances to create with exact argv", %{plan: plan} do
      assert {:ok, state, _} = Unit.new(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(state, :verify_absent, success_list([]))

      assert state.stage == :create
      assert state.create_attempted == true
      assert effects == [{:run, :create, plan.argv.create}]
    end

    @tag :security_regression
    test "security regression: name collision fails without delete or cleanup", %{plan: plan} do
      assert {:ok, state, _} = Unit.new(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(
                 state,
                 :verify_absent,
                 success_list([%{"configuration" => %{"id" => @name}}])
               )

      assert state.stage == :terminal
      assert [{:terminal, terminal}] = effects
      assert terminal["status"] == "error"
      assert terminal["reason"] == "unit_name_collision"

      refute Enum.any?(effects, fn
               {:run, :delete, _} -> true
               {:run, :force_stop, _} -> true
               _ -> false
             end)

      shown = Unit.show(state)
      refute inspect(shown) =~ "stdout"
      refute Map.has_key?(shown, "stdout")
    end

    test "malformed, nonzero, truncated, or unclean list is not absence", %{plan: plan} do
      assert {:ok, base, _} = Unit.new(plan)

      cases = [
        success(%{exit_code: 1, stdout: "[]"}),
        success(%{stdout: "not-json"}),
        success(%{stdout: "{}"}),
        success(%{stdout: Jason.encode!([%{"configuration" => %{}}])}),
        success(%{stdout: Jason.encode!([%{"configuration" => %{"id" => ""}}])}),
        success(%{timed_out: true, stdout: "[]"}),
        success(%{cancelled: true, stdout: "[]"}),
        success(%{output_limit_exceeded: true, stdout: "[]"}),
        success(%{containment_failure: true, stdout: "[]"})
      ]

      for result <- cases do
        assert {:ok, state, [{:terminal, terminal}]} =
                 Unit.apply_result(base, :verify_absent, result)

        assert state.stage == :terminal
        assert terminal["status"] == "error"
        refute terminal["reason"] in [nil, "ok"]
      end
    end
  end

  describe "create and start" do
    test "create success advances to start; start success withholds terminal until absence", %{
      plan: plan
    } do
      state = through_create_pending(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(state, :create, success(%{exit_code: 0}))

      assert state.stage == :start
      assert effects == [{:run, :start, plan.argv.start}]

      assert {:ok, state, effects} =
               Unit.apply_result(state, :start, success(%{exit_code: 0}))

      assert state.stage == :cleanup
      assert state.cleanup_step == :force_stop
      assert state.primary.status == :ok
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]

      # No terminal success yet.
      refute Enum.any?(effects, &match?({:terminal, _}, &1))
    end

    test "create failure still enters cleanup", %{plan: plan} do
      state = through_create_pending(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(state, :create, success(%{exit_code: 1}))

      assert state.stage == :cleanup
      assert state.primary.status == :error
      assert state.primary.reason == :create_failed
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]
    end

    test "start nonzero/timeout/output/cancel all withhold terminal until positive absence", %{
      plan: plan
    } do
      for result <- [
            success(%{exit_code: 2}),
            success(%{timed_out: true, exit_code: 137}),
            success(%{output_limit_exceeded: true, exit_code: 0}),
            success(%{cancelled: true, exit_code: 137})
          ] do
        state = through_start_pending(plan)

        assert {:ok, state, effects} = Unit.apply_result(state, :start, result)
        assert state.stage == :cleanup
        assert effects == [{:run, :force_stop, plan.argv.force_stop}]
        refute Enum.any?(effects, &match?({:terminal, %{"status" => "ok"}}, &1))
      end
    end
  end

  describe "cleanup enforcement" do
    test "cleanup sequences force_stop, force delete, verify_absent", %{plan: plan} do
      state = through_start_success_cleanup(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))

      assert state.cleanup_step == :delete
      assert effects == [{:run, :delete, plan.argv.delete}]

      assert plan.argv.delete == [
               "/usr/local/bin/container",
               "delete",
               "--force",
               @name
             ]

      assert {:ok, state, effects} =
               Unit.apply_result(state, :delete, success(%{exit_code: 0}))

      assert state.cleanup_step == :verify_absent
      assert effects == [{:run, :verify_absent, plan.argv.verify_absent}]
    end

    test "force-stop or delete failure still reaches verify and retries on presence", %{
      plan: plan
    } do
      state = through_start_success_cleanup(plan)

      assert {:ok, state, _} =
               Unit.apply_result(state, :force_stop, success(%{exit_code: 1}))

      assert {:ok, state, _} =
               Unit.apply_result(state, :delete, success(%{exit_code: 1}))

      # Unit still present — must loop, never terminal ok.
      assert {:ok, state, effects} =
               Unit.apply_result(
                 state,
                 :verify_absent,
                 success_list([%{"configuration" => %{"id" => @name}}])
               )

      assert state.stage == :cleanup
      assert state.cleanup_step == :force_stop
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]
      refute Enum.any?(effects, &match?({:terminal, _}, &1))
    end

    test "positive absence after start success emits terminal ok", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      assert {:ok, state, [{:terminal, terminal}]} =
               Unit.apply_result(state, :verify_absent, success_list([]))

      assert state.stage == :terminal
      assert terminal["status"] == "ok"
      assert terminal["exit_code"] == 0
      refute Map.has_key?(terminal, "stdout")
    end

    test "positive absence after create failure emits terminal error primary", %{plan: plan} do
      state = through_create_pending(plan)

      assert {:ok, state, _} =
               Unit.apply_result(state, :create, success(%{exit_code: 9}))

      assert {:ok, state, _} =
               Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))

      assert {:ok, state, _} =
               Unit.apply_result(state, :delete, success(%{exit_code: 0}))

      assert {:ok, state, [{:terminal, terminal}]} =
               Unit.apply_result(state, :verify_absent, success_list([]))

      assert state.stage == :terminal
      assert terminal["status"] == "error"
      assert terminal["reason"] == "create_failed"
    end

    @tag :security_regression
    test "security regression: no transition returns success while unit may exist", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      # Present unit blocks terminal success.
      assert {:ok, state, effects} =
               Unit.apply_result(
                 state,
                 :verify_absent,
                 success_list([%{"configuration" => %{"id" => @name}}])
               )

      refute Enum.any?(effects, fn
               {:terminal, %{"status" => "ok"}} -> true
               _ -> false
             end)

      assert state.stage == :cleanup

      # Unclean list is not absence.
      assert {:ok, state, _} =
               Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))

      assert {:ok, state, _} =
               Unit.apply_result(state, :delete, success(%{exit_code: 0}))

      assert {:ok, state, effects2} =
               Unit.apply_result(state, :verify_absent, success(%{exit_code: 1, stdout: "[]"}))

      refute Enum.any?(effects2, fn
               {:terminal, %{"status" => "ok"}} -> true
               _ -> false
             end)

      assert state.stage == :cleanup
    end

    test "repeated cleanup failure stays memory-bounded", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      state =
        Enum.reduce(1..40, state, fn _, acc ->
          assert {:ok, acc, _} =
                   Unit.apply_result(
                     acc,
                     :verify_absent,
                     success_list([%{"configuration" => %{"id" => @name}}])
                   )

          assert {:ok, acc, _} =
                   Unit.apply_result(acc, :force_stop, success(%{exit_code: 1}))

          assert {:ok, acc, _} =
                   Unit.apply_result(acc, :delete, success(%{exit_code: 1}))

          acc
        end)

      assert length(state.cleanup_diagnostics) <= 16
      shown = Unit.show(state)
      assert length(shown["cleanup_diagnostics"]) <= 16
      assert is_integer(shown["cleanup_round"])
      assert Jason.encode!(shown)
      refute inspect(shown) =~ "configuration"
    end
  end

  describe "cancellation" do
    test "cancel before create terminates cancelled", %{plan: plan} do
      assert {:ok, state, _} = Unit.new(plan)
      assert {:ok, state, [{:terminal, terminal}]} = Unit.cancel(state)
      assert state.stage == :terminal
      assert terminal["status"] == "cancelled"
      assert terminal["reason"] == "preflight_cancelled"
    end

    test "cancel after create enters cleanup", %{plan: plan} do
      state = through_create_pending(plan)
      assert {:ok, state, effects} = Unit.cancel(state)
      assert state.stage == :cleanup
      assert state.primary.status == :cancelled
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]
    end
  end

  describe "show and purity" do
    test "show never leaks setup or cleanup stdout", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      assert {:ok, state, _} =
               Unit.apply_result(
                 state,
                 :verify_absent,
                 success(%{
                   exit_code: 0,
                   stdout: Jason.encode!([%{"configuration" => %{"id" => "other"}}])
                 })
               )

      shown = Unit.show(state)
      text = inspect(shown)
      refute text =~ "stdout"
      refute text =~ "configuration"
      refute Map.has_key?(shown, "stdout")
      assert Jason.encode!(shown)
    end

    test "module source has no impure calls" do
      path =
        Path.expand(
          "../../../lib/arbor/shell/apple_container_unit_core.ex",
          __DIR__
        )

      source = File.read!(path)

      for forbidden <- [
            "File.",
            "System.",
            "Application.",
            "GenServer.",
            ":ets.",
            "Process.",
            "DateTime.utc_now",
            "make_ref",
            "String.to_atom"
          ] do
        refute source =~ forbidden, "unit core must not call #{forbidden}"
      end
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp through_create_pending(plan) do
    assert {:ok, state, _} = Unit.new(plan)

    assert {:ok, state, _} =
             Unit.apply_result(state, :verify_absent, success_list([]))

    state
  end

  defp through_start_pending(plan) do
    state = through_create_pending(plan)

    assert {:ok, state, _} =
             Unit.apply_result(state, :create, success(%{exit_code: 0}))

    state
  end

  defp through_start_success_cleanup(plan) do
    state = through_start_pending(plan)

    assert {:ok, state, _} =
             Unit.apply_result(state, :start, success(%{exit_code: 0}))

    state
  end

  defp through_cleanup_verify_pending(plan) do
    state = through_start_success_cleanup(plan)

    assert {:ok, state, _} =
             Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))

    assert {:ok, state, _} =
             Unit.apply_result(state, :delete, success(%{exit_code: 0}))

    state
  end

  defp success_list(entries) when is_list(entries) do
    success(%{exit_code: 0, stdout: Jason.encode!(entries)})
  end

  defp success(overrides) when is_map(overrides) do
    Map.merge(
      %{
        exit_code: 0,
        stdout: "",
        timed_out: false,
        cancelled: false,
        output_limit_exceeded: false,
        output_truncated: false,
        containment_failure: false
      },
      overrides
    )
  end
end
