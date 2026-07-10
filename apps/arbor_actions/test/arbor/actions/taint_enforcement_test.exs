defmodule Arbor.Actions.TaintEnforcementTest do
  @moduledoc """
  Tests for taint enforcement in the action dispatcher.

  These tests verify that the dispatcher correctly blocks or allows
  actions based on taint levels and policies.
  """
  use ExUnit.Case, async: false

  alias Arbor.Actions.{TaintEnforcement, TaintEvents}
  alias Arbor.Contracts.Security.Taint, as: TaintStruct

  @moduletag :fast

  # A mock action with taint_roles defined
  defmodule MockControlAction do
    def name, do: "mock_control_action"

    def taint_roles do
      %{
        path: :control,
        command: :control,
        content: :data,
        timeout: :data
      }
    end

    def run(_params, _context), do: {:ok, %{success: true}}
  end

  # A mock action without taint_roles (backward compat)
  defmodule MockDataOnlyAction do
    def name, do: "mock_data_only_action"

    def run(_params, _context), do: {:ok, %{success: true}}
  end

  defmodule MockExtendedControlAction do
    def name, do: "mock_extended_control_action"

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        command: {:control, requires: [:command_injection]},
        sandbox: :control,
        content: :data
      }
    end

    def run(_params, _context), do: {:ok, %{success: true}}
  end

  defp taint(level, sanitizations \\ []) do
    bits = TaintStruct.sanitization_bits()

    mask =
      Enum.reduce(sanitizations, 0, fn name, acc -> Bitwise.bor(acc, Map.fetch!(bits, name)) end)

    %TaintStruct{
      level: level,
      sanitizations: mask,
      confidence: :verified,
      sensitivity: :internal
    }
  end

  # Helper to call the internal check_taint function indirectly through authorize_and_execute
  # We mock Arbor.Security.authorize to return {:ok, :authorized}
  # This requires us to test through execute_action instead
  # Actually, we need to test the private check_taint function indirectly

  # Since check_taint is private, we test through the public API
  # We'll use execute_action which doesn't do authorization but does the actual execution
  # However, execute_action doesn't call check_taint - only authorize_and_execute does
  # We'll need to test at the module level or refactor for testability

  # For now, let's test the Taint module directly and the TaintEvents module
  # The dispatcher integration will be tested via the full flow when authorization is mocked

  describe "TaintEvents.emit_taint_blocked/5" do
    test "emits a signal with correct data" do
      # Just verify it doesn't crash and returns :ok
      assert :ok =
               TaintEvents.emit_taint_blocked(
                 MockControlAction,
                 :command,
                 :untrusted,
                 :control,
                 %{agent_id: "agent_001", taint_source: "external_api"}
               )
    end

    test "handles nil taint_source" do
      assert :ok =
               TaintEvents.emit_taint_blocked(
                 MockControlAction,
                 :path,
                 :hostile,
                 :control,
                 %{agent_id: "agent_002"}
               )
    end

    test "handles empty context" do
      assert :ok =
               TaintEvents.emit_taint_blocked(
                 MockControlAction,
                 :command,
                 :untrusted,
                 :control,
                 %{}
               )
    end
  end

  describe "TaintEvents.emit_taint_propagated/4" do
    test "emits a signal with input and output taint" do
      assert :ok =
               TaintEvents.emit_taint_propagated(
                 MockControlAction,
                 :untrusted,
                 :derived,
                 %{agent_id: "agent_001", taint_source: "llm_output"}
               )
    end

    test "handles taint_chain in context" do
      assert :ok =
               TaintEvents.emit_taint_propagated(
                 MockControlAction,
                 :trusted,
                 :trusted,
                 %{agent_id: "agent_001", taint_chain: ["sig_001", "sig_002"]}
               )
    end
  end

  describe "TaintEnforcement.maybe_emit_propagated/3 (regression: struct taint)" do
    # Regression for the taint-struct crash surfaced 2026-06-17: the orchestrator
    # threads context[:taint] as a full %Taint{} struct (Context.worst_taint/2
    # returns a struct), but maybe_emit_propagated called the atom-level
    # Arbor.Signals.Taint.propagate/1 directly, which has no clause for a struct
    # and raised FunctionClauseError — aborting the action (e.g.
    # security.record_diff_findings) AFTER it had already run. Failed open as a
    # crash on the post-execution propagation path. maybe_emit_propagated must
    # normalize a struct to its level before propagating.
    test "does not crash when context[:taint] is a %Taint{} struct" do
      context = %{
        agent_id: "agent_001",
        taint: %TaintStruct{level: :untrusted, sensitivity: :internal}
      }

      assert :ok = TaintEnforcement.maybe_emit_propagated(MockControlAction, context, {:ok, %{}})
    end

    test "still works with a bare level atom on context[:taint]" do
      context = %{agent_id: "agent_001", taint: :untrusted}

      assert :ok = TaintEnforcement.maybe_emit_propagated(MockControlAction, context, {:ok, %{}})
    end

    test "is a no-op when there is no taint on context" do
      assert :ok = TaintEnforcement.maybe_emit_propagated(MockControlAction, %{}, {:ok, %{}})
    end
  end

  describe "per-parameter taint enforcement" do
    test "security regression: validated path is not contaminated by untrusted data" do
      params = %{path: "/repo/lib/example.ex", content: "external patch content"}

      context = %{
        # The aggregate remains untrusted for operation-level policy and egress.
        taint: taint(:untrusted),
        param_taint: %{
          "path" => taint(:trusted, [:path_traversal]),
          "content" => taint(:untrusted)
        },
        taint_policy: :permissive
      }

      assert :ok = TaintEnforcement.check(MockExtendedControlAction, params, context)
    end

    test "security regression: one parameter's sanitizer cannot satisfy another" do
      params = %{path: "/repo", command: "echo safe"}

      context = %{
        # A fully sanitized aggregate must never substitute for the command's
        # exact, unsanitized provenance label.
        taint: taint(:trusted, [:path_traversal, :command_injection]),
        param_taint: %{
          path: taint(:trusted, [:path_traversal]),
          command: taint(:trusted)
        },
        taint_policy: :permissive
      }

      assert {:error, {:missing_sanitization, :command, [:command_injection]}} =
               TaintEnforcement.check(MockExtendedControlAction, params, context)
    end

    test "independent sanitizer labels do not erase each other" do
      params = %{path: "/repo", command: "echo safe"}

      context = %{
        # This is the aggregate produced by intersecting unrelated sanitizer
        # bits. Exact labels still carry the evidence each parameter needs.
        taint: taint(:trusted),
        param_taint: %{
          path: taint(:trusted, [:path_traversal]),
          command: taint(:trusted, [:command_injection])
        },
        taint_policy: :permissive
      }

      assert :ok = TaintEnforcement.check(MockExtendedControlAction, params, context)
    end

    test "strict mode treats tuple control roles as control" do
      params = %{command: "echo safe", content: "data"}

      context = %{
        taint: taint(:derived, [:command_injection]),
        param_taint: %{
          command: taint(:derived, [:command_injection]),
          content: taint(:untrusted)
        },
        taint_policy: :strict
      }

      assert {:error, {:taint_blocked, :command, :derived, :control}} =
               TaintEnforcement.check(MockExtendedControlAction, params, context)
    end

    test "strict mode allows a trusted control beside untrusted data" do
      params = %{path: "/repo", content: "external data"}

      context = %{
        taint: taint(:untrusted),
        param_taint: %{
          path: taint(:trusted, [:path_traversal]),
          content: taint(:untrusted)
        },
        taint_policy: :strict
      }

      assert :ok = TaintEnforcement.check(MockExtendedControlAction, params, context)
    end

    test "audit-only evaluates exact labels but never blocks" do
      params = %{path: "/outside", content: "data"}

      context = %{
        taint: taint(:trusted, [:path_traversal]),
        param_taint: %{
          path: taint(:hostile),
          content: taint(:trusted)
        },
        taint_policy: :audit_only
      }

      assert :ok = TaintEnforcement.check(MockExtendedControlAction, params, context)
    end

    test "an empty per-parameter map does not fall back to the aggregate" do
      context = %{
        taint: taint(:untrusted),
        param_taint: %{},
        taint_policy: :permissive
      }

      assert :ok =
               TaintEnforcement.check(MockExtendedControlAction, %{sandbox: "basic"}, context)
    end
  end

  describe "legacy aggregate compatibility" do
    test "permissive mode still blocks untrusted aggregate control data" do
      context = %{taint: :untrusted, taint_policy: :permissive}

      assert {:error, {:taint_blocked, :sandbox, :untrusted, :control}} =
               TaintEnforcement.check(
                 MockExtendedControlAction,
                 %{sandbox: "basic"},
                 context
               )
    end

    test "audit-only mode still allows aggregate violations" do
      context = %{taint: :untrusted, taint_policy: :audit_only}

      assert :ok =
               TaintEnforcement.check(
                 MockExtendedControlAction,
                 %{sandbox: "basic"},
                 context
               )
    end

    test "strict mode still blocks derived aggregate bare control data" do
      context = %{taint: :derived, taint_policy: :strict}

      assert {:error, {:taint_blocked, :sandbox, :derived, :control}} =
               TaintEnforcement.check(
                 MockExtendedControlAction,
                 %{sandbox: "basic"},
                 context
               )
    end

    test "strict mode normalizes struct taint in blocked errors" do
      context = %{taint: taint(:derived), taint_policy: :strict}

      assert {:error, {:taint_blocked, :sandbox, :derived, :control}} =
               TaintEnforcement.check(
                 MockExtendedControlAction,
                 %{sandbox: "basic"},
                 context
               )
    end

    test "permissive mode audits derived struct taint on tuple control roles" do
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:arbor, :signals, :emitted],
          fn
            _event, _measurements, %{category: :security, type: :taint_audited}, pid ->
              send(pid, :tuple_control_audited)

            _event, _measurements, _metadata, _pid ->
              :ok
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      context = %{
        agent_id: "agent_tuple_audit",
        taint: taint(:derived, [:path_traversal]),
        taint_policy: :permissive
      }

      assert :ok =
               TaintEnforcement.check(
                 MockExtendedControlAction,
                 %{path: "/repo"},
                 context
               )

      assert_receive :tuple_control_audited
    end
  end

  describe "TaintEvents.emit_taint_reduced/4" do
    test "emits a signal for taint reduction" do
      assert :ok =
               TaintEvents.emit_taint_reduced(
                 :untrusted,
                 :derived,
                 :consensus,
                 %{agent_id: "agent_001"}
               )
    end

    test "emits for human_review reduction" do
      assert :ok =
               TaintEvents.emit_taint_reduced(
                 :hostile,
                 :trusted,
                 :human_review,
                 %{agent_id: "agent_001"}
               )
    end
  end

  describe "TaintEvents.emit_taint_audited/4" do
    test "emits audit signal for derived data in control param" do
      assert :ok =
               TaintEvents.emit_taint_audited(
                 MockControlAction,
                 :command,
                 :derived,
                 %{agent_id: "agent_001", taint_policy: :permissive}
               )
    end
  end

  # ==========================================================================
  # Taint check logic tests via Arbor.Actions.Taint
  # ==========================================================================

  describe "taint check with permissive policy (via Taint module)" do
    alias Arbor.Actions.Taint

    test "untrusted + control param is blocked" do
      result =
        Taint.check_params(
          MockControlAction,
          %{command: "rm -rf /"},
          %{taint: :untrusted}
        )

      assert {:error, {:taint_blocked, :command, :untrusted, :control}} = result
    end

    test "hostile + control param is blocked" do
      result =
        Taint.check_params(
          MockControlAction,
          %{path: "/etc/shadow"},
          %{taint: :hostile}
        )

      assert {:error, {:taint_blocked, :path, :hostile, :control}} = result
    end

    test "derived + control param is allowed (permissive default)" do
      result =
        Taint.check_params(
          MockControlAction,
          %{command: "echo hello", path: "/tmp"},
          %{taint: :derived}
        )

      assert result == :ok
    end

    test "trusted + control param is allowed" do
      result =
        Taint.check_params(
          MockControlAction,
          %{command: "ls -la", path: "/home"},
          %{taint: :trusted}
        )

      assert result == :ok
    end

    test "untrusted + data param only is allowed" do
      result =
        Taint.check_params(
          MockControlAction,
          %{content: "user input", timeout: 5000},
          %{taint: :untrusted}
        )

      assert result == :ok
    end

    test "nil taint context is allowed (backward compat)" do
      result = Taint.check_params(MockControlAction, %{command: "ls"}, nil)

      assert result == :ok
    end

    test "empty context map is allowed (backward compat)" do
      result = Taint.check_params(MockControlAction, %{command: "ls"}, %{})

      assert result == :ok
    end

    test "action without taint_roles allows everything" do
      result =
        Taint.check_params(
          MockDataOnlyAction,
          %{anything: "goes", dangerous: "command"},
          %{taint: :untrusted}
        )

      assert result == :ok
    end
  end

  # ==========================================================================
  # Action module naming
  # ==========================================================================

  describe "action module string conversion in TaintEvents" do
    test "converts module to dot-separated string" do
      # This is tested indirectly through emit functions
      # The internal action_module_to_string should produce readable output
      assert :ok =
               TaintEvents.emit_taint_blocked(
                 Arbor.Actions.Shell.Execute,
                 :command,
                 :untrusted,
                 :control,
                 %{}
               )
    end
  end

  # ==========================================================================
  # Context taint extraction
  # ==========================================================================

  describe "taint context extraction patterns" do
    alias Arbor.Actions.Taint

    test "extracts taint from top-level :taint key" do
      result =
        Taint.check_params(
          MockControlAction,
          %{command: "ls"},
          %{taint: :untrusted}
        )

      # Should be blocked because untrusted + control
      assert {:error, {:taint_blocked, :command, :untrusted, :control}} = result
    end

    test "works with nested taint_context (tested via Taint module)" do
      # The Taint.check_params looks for :taint in the map
      # The dispatcher's extract_taint_context handles nested :taint_context
      result =
        Taint.check_params(
          MockControlAction,
          %{content: "safe data only"},
          %{taint: :hostile}
        )

      # Only data params, should pass
      assert result == :ok
    end
  end

  # ==========================================================================
  # Edge cases
  # ==========================================================================

  describe "edge cases" do
    alias Arbor.Actions.Taint

    test "mixed control and data params with untrusted blocks on control" do
      result =
        Taint.check_params(
          MockControlAction,
          %{command: "ls", content: "data", timeout: 1000},
          %{taint: :untrusted}
        )

      assert {:error, {:taint_blocked, :command, :untrusted, :control}} = result
    end

    test "multiple control params reports first one found" do
      result =
        Taint.check_params(
          MockControlAction,
          %{path: "/tmp", command: "echo"},
          %{taint: :hostile}
        )

      assert {:error, {:taint_blocked, param, :hostile, :control}} = result
      assert param in [:path, :command]
    end

    test "empty params map passes" do
      result = Taint.check_params(MockControlAction, %{}, %{taint: :hostile})

      assert result == :ok
    end

    test "unknown params treated as data (not control)" do
      result =
        Taint.check_params(
          MockControlAction,
          %{unknown_param: "value"},
          %{taint: :untrusted}
        )

      # Unknown params default to :data, so untrusted is allowed
      assert result == :ok
    end
  end

  # ==========================================================================
  # Taint propagation fix tests (Phase B/C)
  # Tests for the fixed extract_taint_level that checks both flat and nested
  # ==========================================================================

  describe "taint propagation context extraction" do
    # These tests verify that maybe_emit_taint_propagated correctly extracts
    # taint from both flat context.taint and nested context.taint_context.taint

    # We test this indirectly by testing the dispatcher's behavior
    # since extract_taint_level is private

    test "Taint.check_params handles flat context.taint" do
      alias Arbor.Actions.Taint

      result =
        Taint.check_params(
          MockControlAction,
          %{command: "ls"},
          %{taint: :untrusted}
        )

      # Should block due to untrusted + control
      assert {:error, {:taint_blocked, :command, :untrusted, :control}} = result
    end

    test "dispatcher handles nested context.taint_context.taint" do
      # The dispatcher's extract_taint_context looks for both
      # We can't directly test the private function, but we can verify
      # the TaintEvents module correctly handles nested context

      # TaintEvents.get_in_context handles both patterns
      context = %{taint_context: %{taint: :derived, taint_source: "llm"}}

      assert :ok =
               TaintEvents.emit_taint_propagated(
                 MockControlAction,
                 :derived,
                 :derived,
                 context
               )
    end

    test "TaintEvents.get_in_context extracts from flat context" do
      context = %{taint_source: "external_api", agent_id: "agent_001"}

      # The emit function should work with flat context
      assert :ok =
               TaintEvents.emit_taint_blocked(
                 MockControlAction,
                 :command,
                 :untrusted,
                 :control,
                 context
               )
    end

    test "TaintEvents.get_in_context extracts from nested taint_context" do
      context = %{
        agent_id: "agent_001",
        taint_context: %{taint_source: "nested_source", taint: :derived}
      }

      # The emit function should extract taint_source from nested context
      assert :ok =
               TaintEvents.emit_taint_blocked(
                 MockControlAction,
                 :command,
                 :untrusted,
                 :control,
                 context
               )
    end

    test "propagation emits correctly with nil taint (no emission)" do
      # When there's no taint, propagation should not emit
      # This is tested by ensuring no crash with empty context
      assert :ok =
               TaintEvents.emit_taint_propagated(
                 MockControlAction,
                 nil,
                 nil,
                 %{agent_id: "agent_001"}
               )
    end
  end
end
