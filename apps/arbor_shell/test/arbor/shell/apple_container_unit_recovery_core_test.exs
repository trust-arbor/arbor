defmodule Arbor.Shell.AppleContainerUnitRecoveryCoreTest do
  @moduledoc """
  Exhaustive pure tests for the Apple Container unit recovery CRC core.

  No process execution — command results are injected as plain maps.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerUnitCore, as: Unit
  alias Arbor.Shell.AppleContainerUnitRecoveryCore, as: Recovery

  @moduletag :fast

  @hex32 String.duplicate("a", 32)
  @unit_name "arbor-v1-#{@hex32}"

  @force_stop_argv [
    "/usr/local/bin/container",
    "kill",
    "--signal",
    "KILL",
    @unit_name
  ]

  @delete_argv [
    "/usr/local/bin/container",
    "delete",
    "--force",
    @unit_name
  ]

  @verify_absent_argv [
    "/usr/local/bin/container",
    "list",
    "--all",
    "--format",
    "json"
  ]

  # ---------------------------------------------------------------------------
  # new/1 construction and argv
  # ---------------------------------------------------------------------------

  describe "new/1" do
    test "admits arbor-v1- plus exactly 32 lowercase hex and emits force_stop" do
      assert {:ok, state, effects} = Recovery.new(@unit_name)

      assert state.unit_name == @unit_name
      assert state.stage == :cleanup
      assert state.cleanup_step == :force_stop
      assert state.cleanup_round == 1
      assert state.cleanup_retry_ms == 50
      assert state.cleanup_diagnostics == []
      assert state.terminal == nil

      assert state.argv.force_stop == @force_stop_argv
      assert state.argv.delete == @delete_argv
      assert state.argv.verify_absent == @verify_absent_argv

      assert effects == [{:run, :force_stop, @force_stop_argv}]
    end

    test "fixed argv order is exact kill/delete/list only" do
      assert {:ok, state, _} = Recovery.new(@unit_name)

      assert state.argv.force_stop == [
               "/usr/local/bin/container",
               "kill",
               "--signal",
               "KILL",
               @unit_name
             ]

      assert state.argv.delete == [
               "/usr/local/bin/container",
               "delete",
               "--force",
               @unit_name
             ]

      assert state.argv.verify_absent == [
               "/usr/local/bin/container",
               "list",
               "--all",
               "--format",
               "json"
             ]

      # No shell metacharacters or overrides.
      for argv <- [state.argv.force_stop, state.argv.delete, state.argv.verify_absent] do
        joined = Enum.join(argv, " ")
        refute joined =~ ~r/[;&|`$]/
        refute "sh" in argv
        refute "-c" in argv
      end
    end

    test "is deterministic for the same name" do
      assert {:ok, a, ea} = Recovery.new(@unit_name)
      assert {:ok, b, eb} = Recovery.new(@unit_name)
      assert a == b
      assert ea == eb
      assert Recovery.show(a) == Recovery.show(b)
      assert Jason.encode!(Recovery.show(a))
    end

    test "rejects malformed unit names" do
      bad = [
        "",
        "arbor-v1-",
        "arbor-v1-" <> String.duplicate("a", 31),
        "arbor-v1-" <> String.duplicate("a", 33),
        "arbor-v1-" <> String.duplicate("A", 32),
        "arbor-v1-" <> String.duplicate("g", 32),
        "arbor-v1-" <> @hex32 <> "0",
        "arbor-val-unit1",
        "x" <> @unit_name,
        @unit_name <> "x",
        nil,
        123,
        %{},
        :atom,
        ["arbor-v1-", @hex32]
      ]

      for name <- bad do
        assert {:error, :invalid_unit_name} = Recovery.new(name)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # State machine order
  # ---------------------------------------------------------------------------

  describe "force_stop -> delete -> verify_absent order" do
    test "best-effort force_stop and delete always advance with exact argv" do
      assert {:ok, state, _} = Recovery.new(@unit_name)

      assert {:ok, state, effects} =
               Recovery.apply_result(state, :force_stop, success(%{exit_code: 1}))

      assert state.cleanup_step == :delete
      assert effects == [{:run, :delete, @delete_argv}]

      assert {:ok, state, effects} =
               Recovery.apply_result(state, :delete, success(%{exit_code: 9, timed_out: true}))

      assert state.cleanup_step == :verify_absent
      assert effects == [{:run, :verify_absent, @verify_absent_argv}]
    end

    test "force_stop/delete never emit terminal" do
      for {phase, result} <- [
            {:force_stop, success(%{exit_code: 0})},
            {:force_stop, success(%{exit_code: 1})},
            {:force_stop, success(%{cancelled: true, killed: true})},
            {:force_stop, success(%{containment_failure: true})}
          ] do
        assert {:ok, s0, _} = Recovery.new(@unit_name)

        assert {:ok, _s, effects} = Recovery.apply_result(s0, phase, result)
        refute Enum.any?(effects, &match?({:terminal, _}, &1))
      end

      delete_pending = through_delete_pending()

      for result <- [
            success(%{exit_code: 0}),
            success(%{exit_code: 1}),
            success(%{timed_out: true}),
            success(%{output_limit_exceeded: true})
          ] do
        assert {:ok, _s, effects} = Recovery.apply_result(delete_pending, :delete, result)
        refute Enum.any?(effects, &match?({:terminal, _}, &1))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Absent-only terminal
  # ---------------------------------------------------------------------------

  describe "verification terminal policy" do
    test "only positive absence emits terminal reconciled" do
      state = through_verify_pending()

      assert {:ok, state, effects} =
               Recovery.apply_result(state, :verify_absent, success_list([]))

      assert state.stage == :terminal
      assert state.cleanup_step == nil
      assert state.terminal == :reconciled
      assert effects == [{:terminal, :reconciled}]

      shown = Recovery.show(state)
      assert shown["stage"] == "terminal"
      assert shown["terminal"] == "reconciled"
      assert shown["cleanup_step"] == nil
      assert Jason.encode!(shown)
    end

    test "name present never terminals" do
      state = through_verify_pending()

      assert {:ok, state, effects} =
               Recovery.apply_result(
                 state,
                 :verify_absent,
                 success_list([%{"configuration" => %{"id" => @unit_name}}])
               )

      assert state.stage == :cleanup
      assert state.cleanup_step == :force_stop
      assert state.terminal == nil
      assert [{:retry_after, 50, {:run, :force_stop, @force_stop_argv}}] = effects
      refute Enum.any?(effects, &match?({:terminal, _}, &1))
    end

    test "all failed verification classes retry force_stop" do
      cases = [
        success(%{exit_code: 1, stdout: "[]"}),
        success(%{stdout: "not-json"}),
        success(%{stdout: "{}"}),
        success(%{stdout: Jason.encode!([%{"configuration" => %{}}])}),
        success(%{stdout: Jason.encode!([%{"configuration" => %{"id" => ""}}])}),
        success(%{timed_out: true, stdout: "[]"}),
        success(%{cancelled: true, stdout: "[]"}),
        success(%{output_limit_exceeded: true, stdout: "[]"}),
        success(%{output_truncated: true, stdout: "[]"}),
        success(%{containment_failure: true, stdout: "[]"}),
        success(%{stdout: Jason.encode!([%{"configuration" => %{"id" => @unit_name}}])}),
        "not-a-map",
        nil,
        42
      ]

      for result <- cases do
        assert {:ok, base, _} = Recovery.new(@unit_name)
        base = force_to_verify(base)

        assert {:ok, next, effects} = Recovery.apply_result(base, :verify_absent, result)
        assert next.stage == :cleanup
        assert next.cleanup_step == :force_stop
        assert next.terminal == nil
        assert [{:retry_after, delay, {:run, :force_stop, argv}}] = effects
        assert delay == 50
        assert argv == @force_stop_argv
        refute Enum.any?(effects, &match?({:terminal, _}, &1))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Retry cap / no terminal failure
  # ---------------------------------------------------------------------------

  describe "retry delays and bounds" do
    test "exponential delay 50ms capped at 2000ms with no terminal failure" do
      state = through_verify_pending()

      {delays, state} =
        Enum.map_reduce(1..8, state, fn _, acc ->
          assert {:ok, acc, effects} =
                   Recovery.apply_result(
                     acc,
                     :verify_absent,
                     success_list([%{"configuration" => %{"id" => @unit_name}}])
                   )

          assert [{:retry_after, delay, {:run, :force_stop, @force_stop_argv}}] = effects
          assert delay >= 50
          assert delay <= 2_000
          refute Enum.any?(effects, &match?({:terminal, _}, &1))

          acc = force_to_verify(acc)
          {delay, acc}
        end)

      assert delays == [50, 100, 200, 400, 800, 1600, 2000, 2000]

      # Continue far past cap — still no terminal failure path.
      state =
        Enum.reduce(1..20, state, fn _, acc ->
          assert {:ok, acc, effects} =
                   Recovery.apply_result(
                     acc,
                     :verify_absent,
                     success_list([%{"configuration" => %{"id" => @unit_name}}])
                   )

          assert match?({:retry_after, _, {:run, :force_stop, _}}, hd(effects))
          force_to_verify(acc)
        end)

      assert state.stage == :cleanup
      assert state.terminal == nil
      assert length(state.cleanup_diagnostics) <= 16
      assert state.cleanup_retry_ms == 2_000
      assert state.cleanup_round <= 10_000

      shown = Recovery.show(state)
      assert length(shown["cleanup_diagnostics"]) <= 16
      assert shown["cleanup_retry_ms"] == 2_000
      assert Jason.encode!(shown)
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed name/state/result/replay
  # ---------------------------------------------------------------------------

  describe "fail-closed without mutation" do
    test "unexpected or replayed phases leave state unchanged" do
      assert {:ok, state, _} = Recovery.new(@unit_name)
      freeze = :erlang.term_to_binary(state)

      errors = [
        Recovery.apply_result(state, :delete, success(%{exit_code: 0})),
        Recovery.apply_result(state, :verify_absent, success_list([])),
        Recovery.apply_result(state, :create, success(%{exit_code: 0})),
        Recovery.apply_result(state, :start, success(%{exit_code: 0}))
      ]

      assert Enum.all?(errors, &match?({:error, :unexpected_phase}, &1))
      assert :erlang.term_to_binary(state) == freeze

      # After force_stop, replaying force_stop fails.
      assert {:ok, state, _} =
               Recovery.apply_result(state, :force_stop, success(%{exit_code: 0}))

      freeze = :erlang.term_to_binary(state)

      assert {:error, :unexpected_phase} =
               Recovery.apply_result(state, :force_stop, success(%{exit_code: 0}))

      assert {:error, :unexpected_phase} =
               Recovery.apply_result(state, :verify_absent, success_list([]))

      assert :erlang.term_to_binary(state) == freeze
    end

    test "fabricated state is rejected without exception" do
      assert {:ok, good, _} = Recovery.new(@unit_name)

      fabricated = [
        %{},
        Map.put(good, :extra, true),
        Map.delete(good, :argv),
        %{good | unit_name: "evil"},
        %{good | argv: Map.put(good.argv, :force_stop, good.argv.force_stop ++ ["--x"])},
        %{good | stage: :preflight},
        %{good | cleanup_step: :create},
        %{good | terminal: :reconciled},
        %{good | cleanup_diagnostics: ["not-atom"]},
        %{good | cleanup_retry_ms: 1},
        "nope",
        nil
      ]

      for bad <- fabricated do
        assert {:error, reason} =
                 Recovery.apply_result(bad, :force_stop, success(%{exit_code: 0}))

        assert reason in [:invalid_recovery_state, :invalid_command_result]
        assert {:error, _} = Recovery.show(bad)
      end
    end

    test "non-map force_stop/delete results fail closed without mutation" do
      assert {:ok, state, _} = Recovery.new(@unit_name)
      freeze = :erlang.term_to_binary(state)

      for result <- [nil, "x", 1, [], :ok] do
        assert {:error, :invalid_command_result} =
                 Recovery.apply_result(state, :force_stop, result)
      end

      assert :erlang.term_to_binary(state) == freeze
    end

    test "terminal state rejects further apply_result" do
      state = through_verify_pending()

      assert {:ok, state, [{:terminal, :reconciled}]} =
               Recovery.apply_result(state, :verify_absent, success_list([]))

      freeze = :erlang.term_to_binary(state)

      assert {:error, :recovery_already_terminal} =
               Recovery.apply_result(state, :force_stop, success(%{exit_code: 0}))

      assert {:error, :recovery_already_terminal} =
               Recovery.apply_result(state, :verify_absent, success_list([]))

      assert :erlang.term_to_binary(state) == freeze
    end
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  describe "show/1" do
    test "is deterministic JSON-clean and never leaks stdout" do
      state = through_verify_pending()

      assert {:ok, state, _} =
               Recovery.apply_result(
                 state,
                 :verify_absent,
                 success(%{
                   exit_code: 0,
                   stdout: Jason.encode!([%{"configuration" => %{"id" => "other-secret"}}])
                 })
               )

      # Presence of other id is absence of our unit — terminal.
      assert state.terminal == :reconciled

      shown = Recovery.show(state)
      text = inspect(shown)
      refute text =~ "other-secret"
      refute text =~ "configuration"
      refute Map.has_key?(shown, "stdout")
      refute Map.has_key?(shown, "argv")
      assert Jason.encode!(shown)

      assert {:ok, a, _} = Recovery.new(@unit_name)
      assert Recovery.show(a) == Recovery.show(a)
    end
  end

  # ---------------------------------------------------------------------------
  # UnitCore classifier parity
  # ---------------------------------------------------------------------------

  describe "UnitCore classifier parity" do
    test "recovery verification matches UnitCore.classify_exact_absence/2" do
      results = [
        success_list([]),
        success_list([%{"configuration" => %{"id" => @unit_name}}]),
        success_list([%{"configuration" => %{"id" => "other"}}]),
        success(%{exit_code: 1, stdout: "[]"}),
        success(%{stdout: "not-json"}),
        success(%{timed_out: true, stdout: "[]"}),
        success(%{cancelled: true, stdout: "[]"}),
        success(%{output_limit_exceeded: true, stdout: "[]"}),
        success(%{containment_failure: true, stdout: "[]"}),
        success(%{stdout: Jason.encode!([%{"configuration" => %{}}])}),
        "not-a-map",
        nil
      ]

      for result <- results do
        direct = Unit.classify_exact_absence(@unit_name, result)
        state = through_verify_pending()
        assert {:ok, next, effects} = Recovery.apply_result(state, :verify_absent, result)

        case direct do
          :absent ->
            assert next.terminal == :reconciled
            assert effects == [{:terminal, :reconciled}]

          :present ->
            assert next.cleanup_step == :force_stop
            assert match?({:retry_after, _, {:run, :force_stop, _}}, hd(effects))

          {:error, _} ->
            assert next.cleanup_step == :force_stop
            assert match?({:retry_after, _, {:run, :force_stop, _}}, hd(effects))
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Purity
  # ---------------------------------------------------------------------------

  describe "purity" do
    test "recovery core source contains no impure calls" do
      path =
        Path.expand(
          "../../../lib/arbor/shell/apple_container_unit_recovery_core.ex",
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
            "Port.",
            "Logger.",
            "Task.",
            "DateTime.utc_now",
            "make_ref",
            "String.to_atom",
            ":rand.",
            "send(",
            "receive "
          ] do
        refute source =~ forbidden, "recovery core must not call #{forbidden}"
      end

      # No cross-library facades beyond UnitCore in the same app.
      refute source =~ "Arbor.Security"
      refute source =~ "Arbor.Actions"
      refute source =~ "Arbor.Persistence"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp through_delete_pending do
    assert {:ok, state, _} = Recovery.new(@unit_name)

    assert {:ok, state, _} =
             Recovery.apply_result(state, :force_stop, success(%{exit_code: 0}))

    state
  end

  defp through_verify_pending do
    state = through_delete_pending()

    assert {:ok, state, _} =
             Recovery.apply_result(state, :delete, success(%{exit_code: 0}))

    state
  end

  defp force_to_verify(state) do
    assert {:ok, state, _} =
             Recovery.apply_result(state, :force_stop, success(%{exit_code: 0}))

    assert {:ok, state, _} =
             Recovery.apply_result(state, :delete, success(%{exit_code: 0}))

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
        killed: false,
        output_limit_exceeded: false,
        output_truncated: false,
        containment_failure: false
      },
      overrides
    )
  end
end
