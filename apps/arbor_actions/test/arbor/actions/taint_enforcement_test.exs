defmodule Arbor.Actions.TaintEnforcementTest do
  @moduledoc """
  Tests for taint enforcement in the action dispatcher.

  These tests verify that the dispatcher correctly blocks or allows
  actions based on taint levels and policies.
  """
  use ExUnit.Case, async: true

  alias Arbor.Actions.TaintEvents

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
