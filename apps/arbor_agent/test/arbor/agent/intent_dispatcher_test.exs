defmodule Arbor.Agent.IntentDispatcherTest do
  @moduledoc """
  Unit tests for the pure helpers in `Arbor.Agent.IntentDispatcher` —
  `ensure_actionable/1`, `resolve_action_module/1`,
  `audit_capability_match/3`, `build_action_context/3`. End-to-end
  dispatch through `Arbor.Actions.authorize_and_execute/4` requires
  the full security + persistence supervision tree (covered by
  `arbor_actions` integration tests); here we focus on the dispatcher's
  own logic.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.IntentDispatcher
  alias Arbor.Contracts.Memory.Intent

  defp action_intent(action, opts \\ []) do
    Intent.new(:act,
      action: action,
      params: Keyword.get(opts, :params, %{}),
      capability: Keyword.get(opts, :capability),
      op: Keyword.get(opts, :op),
      target: Keyword.get(opts, :target)
    )
  end

  describe "ensure_actionable/1" do
    test "accepts :act intents" do
      assert :ok = IntentDispatcher.ensure_actionable(Intent.new(:act, []))
    end

    test "rejects :think intents" do
      assert {:error, {:non_actionable_intent, :think}} =
               IntentDispatcher.ensure_actionable(Intent.new(:think, []))
    end

    test "rejects :wait, :reflect, :internal intents" do
      for type <- [:wait, :reflect, :internal] do
        assert {:error, {:non_actionable_intent, ^type}} =
                 IntentDispatcher.ensure_actionable(Intent.new(type, []))
      end
    end
  end

  describe "resolve_action_module/1" do
    test "resolves a known underscore-form action name" do
      intent = action_intent(:file_read)

      assert {:ok, Arbor.Actions.File.Read} =
               IntentDispatcher.resolve_action_module(intent)
    end

    test "resolves a known dotted action atom via name_to_module" do
      # name_to_module accepts both "shell_execute" and "shell.execute" —
      # the atom :shell_execute → "shell_execute" → Shell.Execute.
      intent = action_intent(:shell_execute)

      assert {:ok, Arbor.Actions.Shell.Execute} =
               IntentDispatcher.resolve_action_module(intent)
    end

    test "returns :intent_missing_action when :action is nil" do
      intent = Intent.new(:act, params: %{some: "params"})

      assert {:error, :intent_missing_action} =
               IntentDispatcher.resolve_action_module(intent)
    end

    test "returns :unknown_action for unrecognized action names" do
      intent = action_intent(:totally_nonexistent_action_xyz)

      assert {:error, {:unknown_action, :totally_nonexistent_action_xyz}} =
               IntentDispatcher.resolve_action_module(intent)
    end
  end

  describe "audit_capability_match/3" do
    test "nil capability hint passes (no audit)" do
      assert :ok = IntentDispatcher.audit_capability_match(Arbor.Actions.File.Read, %{}, nil)
    end

    test "empty-string hint passes (no audit)" do
      assert :ok = IntentDispatcher.audit_capability_match(Arbor.Actions.File.Read, %{}, "")
    end

    test "exact-match hint passes" do
      # canonical_uri_for(File.Read, %{}) → "arbor://fs/read"
      assert :ok =
               IntentDispatcher.audit_capability_match(
                 Arbor.Actions.File.Read,
                 %{},
                 "arbor://fs/read"
               )
    end

    test "namespace-prefix hint passes (covers any action under namespace)" do
      assert :ok =
               IntentDispatcher.audit_capability_match(
                 Arbor.Actions.File.Read,
                 %{},
                 "arbor://fs"
               )
    end

    test "mismatched namespace fails (LLM tampering protection)" do
      # File.Read canonical URI is arbor://fs/read; a hint of
      # arbor://shell would be a sign the LLM emitted inconsistent
      # fields (or tried to dispatch a different capability under cover).
      assert {:error, {:capability_mismatch, details}} =
               IntentDispatcher.audit_capability_match(
                 Arbor.Actions.File.Read,
                 %{},
                 "arbor://shell"
               )

      assert details.expected == "arbor://shell"
      assert details.actual == "arbor://fs/read"
      assert details.module =~ "Arbor.Actions.File.Read"
    end

    test "wrong file op in same namespace fails (action :write under hint arbor://fs/read)" do
      # File.Write canonical URI is arbor://fs/write; a hint of
      # arbor://fs/read does NOT cover it (read is not a prefix of write).
      assert {:error, {:capability_mismatch, details}} =
               IntentDispatcher.audit_capability_match(
                 Arbor.Actions.File.Write,
                 %{},
                 "arbor://fs/read"
               )

      assert details.expected == "arbor://fs/read"
      assert details.actual == "arbor://fs/write"
    end
  end

  describe "build_action_context/3" do
    test "always includes agent_id and intent metadata" do
      intent = action_intent(:file_read, params: %{path: "/tmp/x"})

      ctx = IntentDispatcher.build_action_context("agent_test", intent, [])

      assert ctx.agent_id == "agent_test"
      assert ctx.intent_id == intent.id
      assert ctx.intent_goal_id == nil
    end

    test "propagates :goal_id from intent" do
      intent =
        Intent.new(:act,
          action: :file_read,
          goal_id: "goal_abc"
        )

      ctx = IntentDispatcher.build_action_context("agent_x", intent, [])
      assert ctx.intent_goal_id == "goal_abc"
    end

    test "threads :workspace from opts when provided" do
      intent = action_intent(:file_read)

      ctx =
        IntentDispatcher.build_action_context("agent_x", intent, workspace: "/tmp/workspace")

      assert ctx.workspace == "/tmp/workspace"
    end

    test "omits :workspace when not provided" do
      intent = action_intent(:file_read)
      ctx = IntentDispatcher.build_action_context("agent_x", intent, [])
      refute Map.has_key?(ctx, :workspace)
    end

    test "extra opts[:context] keys merge in and override defaults" do
      intent = action_intent(:file_read)

      ctx =
        IntentDispatcher.build_action_context("agent_x", intent,
          context: %{signed_request: %{foo: :bar}, agent_id: "override_attempted"}
        )

      assert ctx.signed_request == %{foo: :bar}
      # Caller's :agent_id wins over our default — explicit > implicit.
      assert ctx.agent_id == "override_attempted"
    end
  end

  describe "dispatch/3 — guards and routing" do
    test "rejects non-:act intents before any module resolution" do
      assert {:error, {:non_actionable_intent, :think}} =
               IntentDispatcher.dispatch("agent_x", Intent.new(:think, []))
    end

    test "rejects intents with nil :action" do
      assert {:error, :intent_missing_action} =
               IntentDispatcher.dispatch("agent_x", Intent.new(:act, []))
    end

    test "rejects intents with unknown :action before authorize_and_execute" do
      intent = action_intent(:not_a_real_action_xyz)

      assert {:error, {:unknown_action, :not_a_real_action_xyz}} =
               IntentDispatcher.dispatch("agent_x", intent)
    end

    test "rejects capability_mismatch before authorize_and_execute" do
      intent =
        action_intent(:file_read,
          params: %{path: "/etc/hosts"},
          capability: "arbor://shell"
        )

      assert {:error, {:capability_mismatch, _}} =
               IntentDispatcher.dispatch("agent_x", intent)
    end
  end
end
