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
    build: "/private/tmp/arbor-val/build",
    deps: "/private/tmp/arbor-val/deps",
    mix_wrapper_dir: "/private/tmp/arbor-val/bin"
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
    command_args: ["test", "apps/arbor_shell/test/example_test.exs"],
    resource_profile: :standard
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

    test "requires exact canonical plan equality", %{plan: plan} do
      assert {:ok, _, _} = Unit.new(plan)

      # Extra field fails closed.
      assert {:error, :plan_not_canonical} = Unit.new(Map.put(plan, :extra, true))

      # Altered lifecycle fails closed.
      altered_life =
        put_in(plan, [:lifecycle, :start_order], [:start, :create])

      assert {:error, :plan_not_canonical} = Unit.new(altered_life)

      # String-keyed show map is not a canonical plan (profile value is a string).
      assert {:error, :invalid_resource_profile} =
               Unit.new(AppleContainerPlanCore.show(plan))

      # Request-only map is not a full plan.
      assert {:error, :plan_not_canonical} = Unit.new(@valid_request)
    end

    @tag :security_regression
    test "security regression: forged argv mutation yields no run effect", %{plan: plan} do
      phases = [:create, :start, :force_stop, :delete, :verify_absent]

      for phase <- phases do
        forged_argv =
          Map.update!(plan.argv, phase, fn argv ->
            argv ++ ["--forged-attacker-flag"]
          end)

        forged = %{plan | argv: forged_argv}

        assert {:error, :plan_not_canonical} = Unit.new(forged)
      end

      # Mutating every phase at once also fails with no effect.
      all_forged =
        Enum.reduce(phases, plan.argv, fn phase, argv ->
          Map.update!(argv, phase, &(&1 ++ ["evil"]))
        end)

      assert {:error, :plan_not_canonical} = Unit.new(%{plan | argv: all_forged})
    end

    test "rejects altered env, mounts, runtime, and limits", %{plan: plan} do
      assert {:error, :plan_not_canonical} =
               Unit.new(%{plan | env: plan.env ++ [{"EVIL", "1"}]})

      assert {:error, :plan_not_canonical} =
               Unit.new(%{plan | mounts: []})

      assert {:error, :plan_not_canonical} =
               Unit.new(%{plan | runtime_executable: "/tmp/evil"})

      assert {:error, :plan_not_canonical} =
               Unit.new(%{plan | resource_limits: %{cpus: "99", memory: "99G"}})
    end

    test "intensive plan remains intensive through canonical re-admission" do
      assert {:ok, intensive} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :resource_profile, :intensive))

      assert intensive.resource_profile == :intensive
      assert intensive.resource_limits == %{cpus: "4", memory: "4G"}

      assert {:ok, state, effects} = Unit.new(intensive)
      assert state.stage == :preflight
      assert effects == [{:run, :verify_absent, intensive.argv.verify_absent}]

      # Re-admitted argv preserves intensive create limits (not standard 1/2).
      create = state.argv.create
      cpus_idx = Enum.find_index(create, &(&1 == "--cpus"))
      memory_idx = Enum.find_index(create, &(&1 == "--memory"))
      assert Enum.at(create, cpus_idx + 1) == "4"
      assert Enum.at(create, memory_idx + 1) == "4G"
      assert state.argv.create == intensive.argv.create
    end

    test "legacy missing-profile plan is reconstructed as explicit standard" do
      assert {:ok, standard} = AppleContainerPlanCore.new(@valid_request)
      assert standard.resource_profile == :standard

      # Plans that predate the field omit resource_profile; reconstruction fills
      # `:standard` and admits when the remainder matches the standard plan.
      legacy = Map.delete(standard, :resource_profile)
      refute Map.has_key?(legacy, :resource_profile)

      assert {:ok, state, effects} = Unit.new(legacy)
      assert state.stage == :preflight
      assert effects == [{:run, :verify_absent, standard.argv.verify_absent}]

      create = state.argv.create
      cpus_idx = Enum.find_index(create, &(&1 == "--cpus"))
      memory_idx = Enum.find_index(create, &(&1 == "--memory"))
      assert Enum.at(create, cpus_idx + 1) == "1"
      assert Enum.at(create, memory_idx + 1) == "2G"
      assert state.argv.create == standard.argv.create

      # Intensive argv without a profile cannot be smuggled as intensive — the
      # missing field reconstructs as standard and equality fails closed.
      assert {:ok, intensive} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :resource_profile, :intensive))

      forged_legacy = Map.delete(intensive, :resource_profile)
      assert {:error, :plan_not_canonical} = Unit.new(forged_legacy)
    end

    @tag :security_regression
    test "rejects forged guest tmpfs path and reintroduced host tmp bind", %{plan: plan} do
      host_tmp = "/private/tmp/arbor-val/tmp"

      # Canonical plan uses dedicated path-only --tmpfs; mounts stay bind-only.
      assert plan.guest_tmpfs == %{guest_path: "/tmp", argv_spec: "/tmp"}
      refute Enum.any?(plan.mounts, &(&1.purpose == :tmp))
      assert Enum.count(plan.argv.create, &(&1 == "--tmpfs")) == 1
      tmpfs_idx = Enum.find_index(plan.argv.create, &(&1 == "--tmpfs"))
      assert Enum.at(plan.argv.create, tmpfs_idx + 1) == "/tmp"

      forged_tmpfs = %{guest_path: "/evil/tmp", argv_spec: "/evil/tmp"}

      forged_argv_path =
        Map.update!(plan.argv, :create, fn create ->
          # Replace only the --tmpfs path token, not arbitrary "/tmp" substrings.
          create
          |> Enum.with_index()
          |> Enum.map(fn
            {token, ^tmpfs_idx} -> token
            {_token, idx} when idx == tmpfs_idx + 1 -> forged_tmpfs.argv_spec
            {token, _} -> token
          end)
        end)

      assert {:error, :plan_not_canonical} =
               Unit.new(%{plan | guest_tmpfs: forged_tmpfs, argv: forged_argv_path})

      # Reintroducing a host tmp bind mount must fail closed.
      forged_mounts =
        plan.mounts ++
          [
            %{
              purpose: :tmp,
              host_path: host_tmp,
              guest_path: "/tmp",
              mode: :read_write,
              mount_spec: "type=bind,source=#{host_tmp},target=/tmp"
            }
          ]

      forged_argv_bind =
        Map.update!(plan.argv, :create, fn create ->
          create
          |> Enum.with_index()
          |> Enum.reject(fn {_token, idx} -> idx in [tmpfs_idx, tmpfs_idx + 1] end)
          |> Enum.map(&elem(&1, 0))
          |> Kernel.++([
            "--mount",
            "type=bind,source=#{host_tmp},target=/tmp"
          ])
        end)

      assert {:error, :plan_not_canonical} =
               Unit.new(%{plan | mounts: forged_mounts, argv: forged_argv_bind})
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
      assert effects == [{:terminal, {:error, :unit_name_collision}}]

      refute Enum.any?(effects, fn
               {:run, :delete, _} -> true
               {:run, :force_stop, _} -> true
               {:retry_after, _, _} -> true
               _ -> false
             end)

      shown = Unit.show(state)
      refute Map.has_key?(shown, "stdout")
      assert shown["terminal"]["reason"] == "unit_name_collision"
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
        assert {:ok, state, [{:terminal, {:error, reason}}]} =
                 Unit.apply_result(base, :verify_absent, result)

        assert state.stage == :terminal
        assert is_atom(reason)
        refute reason in [nil, :ok]
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
               Unit.apply_result(
                 state,
                 :start,
                 success(%{exit_code: 0, stdout: "candidate-out", duration_ms: 12})
               )

      assert state.stage == :cleanup
      assert state.cleanup_step == :force_stop
      assert state.candidate_result.exit_code == 0
      assert state.candidate_result.stdout == "candidate-out"
      assert state.candidate_result.stderr == ""
      assert state.candidate_result.duration_ms == 12
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]

      refute Enum.any?(effects, &match?({:terminal, _}, &1))
    end

    test "create failure still enters cleanup", %{plan: plan} do
      state = through_create_pending(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(state, :create, success(%{exit_code: 1}))

      assert state.stage == :cleanup
      assert state.error_reason == :create_failed
      assert state.candidate_result == nil
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]
    end

    test "start nonzero/timeout/output/cancel/containment withhold terminal until absence", %{
      plan: plan
    } do
      cases = [
        success(%{exit_code: 2, stdout: "fail-out"}),
        success(%{timed_out: true, exit_code: 137, stdout: "partial"}),
        success(%{output_limit_exceeded: true, exit_code: 0, stdout: "big"}),
        success(%{output_truncated: true, exit_code: 0, stdout: "trunc"}),
        success(%{cancelled: true, exit_code: 137, stdout: "c"}),
        success(%{containment_failure: true, exit_code: 137, stdout: "x"})
      ]

      for result <- cases do
        state = through_start_pending(plan)

        assert {:ok, state, effects} = Unit.apply_result(state, :start, result)
        assert state.stage == :cleanup
        assert is_map(state.candidate_result)
        assert effects == [{:run, :force_stop, plan.argv.force_stop}]
        refute Enum.any?(effects, &match?({:terminal, _}, &1))
      end
    end
  end

  describe "phase-aware stdout bounds and strict flags" do
    test "accepts start stdout above 256 KiB within 16 MiB", %{plan: plan} do
      state = through_start_pending(plan)
      big = String.duplicate("x", 300_000)

      assert {:ok, state, _} =
               Unit.apply_result(state, :start, success(%{exit_code: 0, stdout: big}))

      assert state.candidate_result.stdout == big
      assert byte_size(state.candidate_result.stdout) > 262_144
    end

    test "rejects start stdout over public hard maximum", %{plan: plan} do
      state = through_start_pending(plan)
      too_big = String.duplicate("y", 16_777_216 + 1)

      assert {:error, :stdout_too_long} =
               Unit.apply_result(state, :start, success(%{exit_code: 0, stdout: too_big}))
    end

    test "rejects oversized create/cleanup stdout and discards setup output", %{plan: plan} do
      create_state = through_create_pending(plan)
      oversized = String.duplicate("z", 8_192 + 1)

      assert {:error, :stdout_too_long} =
               Unit.apply_result(
                 create_state,
                 :create,
                 success(%{exit_code: 0, stdout: oversized})
               )

      # Successful create with small stdout does not retain that stdout.
      assert {:ok, state, _} =
               Unit.apply_result(
                 create_state,
                 :create,
                 success(%{exit_code: 0, stdout: "create-noise"})
               )

      shown = Unit.show(state)
      refute inspect(shown) =~ "create-noise"
      assert state.candidate_result == nil

      # Cleanup force-stop oversized stdout rejected.
      start_cleanup = through_start_success_cleanup(plan)

      assert {:error, :stdout_too_long} =
               Unit.apply_result(
                 start_cleanup,
                 :force_stop,
                 success(%{exit_code: 0, stdout: oversized})
               )
    end

    test "rejects duplicate atom/string result-key aliases", %{plan: plan} do
      state = through_start_pending(plan)

      assert {:error, {:duplicate_result_key_alias, :exit_code}} =
               Unit.apply_result(
                 state,
                 :start,
                 Map.put(success(%{exit_code: 0}), "exit_code", 1)
               )

      assert {:error, {:duplicate_result_key_alias, :timed_out}} =
               Unit.apply_result(
                 state,
                 :start,
                 Map.merge(success(%{exit_code: 0}), %{"timed_out" => true, timed_out: false})
               )
    end

    test "rejects non-boolean flag values; missing flags default false", %{plan: plan} do
      state = through_start_pending(plan)

      assert {:error, {:invalid_boolean_flag, :timed_out}} =
               Unit.apply_result(
                 state,
                 :start,
                 %{exit_code: 0, stdout: "", timed_out: "yes"}
               )

      assert {:ok, state, _} =
               Unit.apply_result(state, :start, %{exit_code: 0, stdout: "ok"})

      assert state.candidate_result.timed_out == false
      assert state.candidate_result.killed == false
      assert state.candidate_result.output_truncated == false
      assert state.candidate_result.output_limit_exceeded == false
      refute Map.has_key?(state.candidate_result, :cancelled)
      refute Map.has_key?(state.candidate_result, :containment_failure)
    end
  end

  describe "candidate result preservation" do
    test "preserves exit 0 candidate fields through terminal", %{plan: plan} do
      state = through_start_pending(plan)

      assert {:ok, state, _} =
               Unit.apply_result(
                 state,
                 :start,
                 success(%{
                   exit_code: 0,
                   stdout: "hello",
                   duration_ms: 42
                 })
               )

      assert state.candidate_result == %{
               exit_code: 0,
               stdout: "hello",
               stderr: "",
               duration_ms: 42,
               timed_out: false,
               killed: false,
               output_truncated: false,
               output_limit_exceeded: false
             }

      assert {:ok, state, [{:terminal, {:ok, result}}]} =
               finish_cleanup_absent(state)

      assert result == state.candidate_result
      assert result.stdout == "hello"
      assert Unit.show(state)["candidate_result"]["stdout"] == "hello"
      assert Unit.show(state)["terminal"]["result"]["stdout"] == "hello"
    end

    test "nonzero candidate exit is terminal ok data after absence", %{plan: plan} do
      state = through_start_pending(plan)

      assert {:ok, state, _} =
               Unit.apply_result(
                 state,
                 :start,
                 success(%{exit_code: 7, stdout: "tests failed"})
               )

      assert {:ok, state, [{:terminal, {:ok, result}}]} =
               finish_cleanup_absent(state)

      assert result.exit_code == 7
      assert result.stdout == "tests failed"
      assert state.stage == :terminal
    end

    test "timeout/output/cancel/containment candidates remain {:ok, result}", %{plan: plan} do
      cases = [
        success(%{timed_out: true, killed: true, exit_code: 137, stdout: "t"}),
        success(%{
          output_limit_exceeded: true,
          output_truncated: true,
          killed: true,
          exit_code: 0,
          stdout: "o"
        }),
        success(%{cancelled: true, killed: true, exit_code: 137, stdout: "c"}),
        success(%{containment_failure: true, killed: true, exit_code: 137, stdout: "x"})
      ]

      for result <- cases do
        state = through_start_pending(plan)
        assert {:ok, state, _} = Unit.apply_result(state, :start, result)
        assert {:ok, _state, [{:terminal, {:ok, retained}}]} = finish_cleanup_absent(state)
        assert retained.stdout == result.stdout
        assert retained.exit_code == result.exit_code
      end
    end

    test "create failure terminal is error after cleanup absence", %{plan: plan} do
      state = through_create_pending(plan)

      assert {:ok, state, _} =
               Unit.apply_result(state, :create, success(%{exit_code: 9}))

      assert {:ok, state, [{:terminal, {:error, :create_failed}}]} =
               finish_cleanup_absent(state)

      assert state.candidate_result == nil
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

      assert {:ok, state, effects} =
               Unit.apply_result(
                 state,
                 :verify_absent,
                 success_list([%{"configuration" => %{"id" => @name}}])
               )

      assert state.stage == :cleanup
      assert state.cleanup_step == :force_stop
      assert [{:retry_after, 50, {:run, :force_stop, force_stop}}] = effects
      assert force_stop == plan.argv.force_stop
      refute Enum.any?(effects, &match?({:terminal, _}, &1))
    end

    test "positive absence after start success emits terminal ok result", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      assert {:ok, state, [{:terminal, {:ok, result}}]} =
               Unit.apply_result(state, :verify_absent, success_list([]))

      assert state.stage == :terminal
      assert result.exit_code == 0
      assert result.stderr == ""
    end

    test "positive absence after create failure emits terminal error", %{plan: plan} do
      state = through_create_pending(plan)

      assert {:ok, state, _} =
               Unit.apply_result(state, :create, success(%{exit_code: 9}))

      assert {:ok, state, _} =
               Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))

      assert {:ok, state, _} =
               Unit.apply_result(state, :delete, success(%{exit_code: 0}))

      assert {:ok, state, [{:terminal, {:error, :create_failed}}]} =
               Unit.apply_result(state, :verify_absent, success_list([]))

      assert state.stage == :terminal
    end

    @tag :security_regression
    test "security regression: no transition returns success while unit may exist", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      assert {:ok, state, effects} =
               Unit.apply_result(
                 state,
                 :verify_absent,
                 success_list([%{"configuration" => %{"id" => @name}}])
               )

      refute Enum.any?(effects, fn
               {:terminal, {:ok, _}} -> true
               _ -> false
             end)

      assert state.stage == :cleanup
      assert match?({:retry_after, _, {:run, :force_stop, _}}, hd(effects))

      assert {:ok, state, _} =
               Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))

      assert {:ok, state, _} =
               Unit.apply_result(state, :delete, success(%{exit_code: 0}))

      assert {:ok, state, effects2} =
               Unit.apply_result(state, :verify_absent, success(%{exit_code: 1, stdout: "[]"}))

      refute Enum.any?(effects2, fn
               {:terminal, {:ok, _}} -> true
               _ -> false
             end)

      assert state.stage == :cleanup
    end

    test "bounded exponential retry delays and memory", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      {delays, state} =
        Enum.map_reduce(1..8, state, fn _, acc ->
          assert {:ok, acc, effects} =
                   Unit.apply_result(
                     acc,
                     :verify_absent,
                     success_list([%{"configuration" => %{"id" => @name}}])
                   )

          assert [{:retry_after, delay, {:run, :force_stop, _}}] = effects
          assert delay >= 50
          assert delay <= 2_000

          assert {:ok, acc, _} =
                   Unit.apply_result(acc, :force_stop, success(%{exit_code: 1}))

          assert {:ok, acc, _} =
                   Unit.apply_result(acc, :delete, success(%{exit_code: 1}))

          {delay, acc}
        end)

      assert delays == [50, 100, 200, 400, 800, 1600, 2000, 2000]

      # Continue looping for diagnostic bound.
      state =
        Enum.reduce(1..20, state, fn _, acc ->
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
      assert is_integer(shown["cleanup_retry_ms"])
      assert shown["cleanup_retry_ms"] <= 2_000
      assert Jason.encode!(shown)
      refute inspect(shown) =~ "configuration"
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

    test "cancel while start pending enters cleanup without terminal", %{plan: plan} do
      state = through_start_pending(plan)
      assert {:ok, state, effects} = Unit.cancel(state)
      assert state.stage == :cleanup
      assert effects == [{:run, :force_stop, plan.argv.force_stop}]
      refute Enum.any?(effects, &match?({:terminal, _}, &1))
    end
  end

  describe "classify_exact_absence/2" do
    test "classifies absent, present, and error classes from raw shell results" do
      assert :absent = Unit.classify_exact_absence(@name, success_list([]))

      assert :absent =
               Unit.classify_exact_absence(
                 @name,
                 success_list([%{"configuration" => %{"id" => "other"}}])
               )

      assert :present =
               Unit.classify_exact_absence(
                 @name,
                 success_list([%{"configuration" => %{"id" => @name}}])
               )

      assert {:error, :list_nonzero_exit} =
               Unit.classify_exact_absence(@name, success(%{exit_code: 1, stdout: "[]"}))

      assert {:error, :list_invalid_json} =
               Unit.classify_exact_absence(@name, success(%{stdout: "not-json"}))

      assert {:error, :list_timeout} =
               Unit.classify_exact_absence(@name, success(%{timed_out: true, stdout: "[]"}))

      assert {:error, :list_cancelled} =
               Unit.classify_exact_absence(@name, success(%{cancelled: true, stdout: "[]"}))

      assert {:error, :list_output_limit} =
               Unit.classify_exact_absence(
                 @name,
                 success(%{output_limit_exceeded: true, stdout: "[]"})
               )

      assert {:error, :list_containment_failure} =
               Unit.classify_exact_absence(
                 @name,
                 success(%{containment_failure: true, stdout: "[]"})
               )
    end

    test "malformed names and results fail closed without raising" do
      assert {:error, :invalid_unit_name} = Unit.classify_exact_absence("", success_list([]))
      assert {:error, :invalid_unit_name} = Unit.classify_exact_absence(nil, success_list([]))
      assert {:error, :invalid_unit_name} = Unit.classify_exact_absence(123, success_list([]))

      too_long = String.duplicate("x", 257)

      assert {:error, :invalid_unit_name} =
               Unit.classify_exact_absence(too_long, success_list([]))

      assert {:error, :invalid_command_result} = Unit.classify_exact_absence(@name, "nope")
      assert {:error, :invalid_command_result} = Unit.classify_exact_absence(@name, nil)
      assert {:error, :missing_exit_code} = Unit.classify_exact_absence(@name, %{stdout: "[]"})

      assert {:error, :unsupported_result_keys} =
               Unit.classify_exact_absence(@name, %{exit_code: 0, evil: true})
    end

    test "matches lifecycle cleanup absence classification", %{plan: plan} do
      state = through_cleanup_verify_pending(plan)

      raw = success_list([])
      assert :absent = Unit.classify_exact_absence(@name, raw)

      assert {:ok, _state, [{:terminal, {:ok, _}}]} =
               Unit.apply_result(state, :verify_absent, raw)

      present = success_list([%{"configuration" => %{"id" => @name}}])
      assert :present = Unit.classify_exact_absence(@name, present)

      assert {:ok, _state, [{:retry_after, _, {:run, :force_stop, _}}]} =
               Unit.apply_result(state, :verify_absent, present)
    end
  end

  describe "show and purity" do
    test "show never leaks setup or cleanup stdout", %{plan: plan} do
      state = through_start_success_cleanup(plan)

      assert {:ok, state, _} =
               Unit.apply_result(
                 state,
                 :force_stop,
                 success(%{exit_code: 0, stdout: "force-stop-secret"})
               )

      assert {:ok, state, _} =
               Unit.apply_result(
                 state,
                 :delete,
                 success(%{exit_code: 0, stdout: "delete-secret"})
               )

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
      refute text =~ "force-stop-secret"
      refute text =~ "delete-secret"
      refute text =~ "configuration"
      refute Map.has_key?(shown, "stdout")
      # Candidate stdout from start success is empty string (no payload), not cleanup.
      assert shown["candidate_result"]["stdout"] == ""
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

  defp finish_cleanup_absent(state) do
    assert {:ok, state, _} =
             Unit.apply_result(state, :force_stop, success(%{exit_code: 0}))

    assert {:ok, state, _} =
             Unit.apply_result(state, :delete, success(%{exit_code: 0}))

    Unit.apply_result(state, :verify_absent, success_list([]))
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
        killed: false,
        output_limit_exceeded: false,
        output_truncated: false,
        containment_failure: false
      },
      overrides
    )
  end
end
