defmodule Arbor.Contracts.Security.CapabilityPhase2Test do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Capability

  @valid_attrs [
    resource_uri: "arbor://fs/read/docs",
    principal_id: "agent_test001"
  ]

  # ── 2.1 Session-Bound Capabilities ───────────────────────────────

  describe "session-bound capabilities" do
    @tag :fast
    test "capabilities are not session-bound by default" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert cap.session_id == nil
    end

    @tag :fast
    test "can create session-bound capability" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [session_id: "session_abc123"])
      assert cap.session_id == "session_abc123"
    end

    @tag :fast
    test "unbound capability matches any session" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert Capability.scope_matches?(cap, session_id: "session_abc123")
      assert Capability.scope_matches?(cap, [])
      assert Capability.scope_matches?(cap)
    end

    @tag :fast
    test "session-bound capability matches correct session" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [session_id: "session_abc123"])
      assert Capability.scope_matches?(cap, session_id: "session_abc123")
    end

    @tag :fast
    test "session-bound capability rejects wrong session" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [session_id: "session_abc123"])
      refute Capability.scope_matches?(cap, session_id: "session_other")
    end

    @tag :fast
    test "session-bound capability rejects missing session in context" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [session_id: "session_abc123"])
      refute Capability.scope_matches?(cap, [])
    end

    @tag :fast
    test "delegation inherits session_id from parent" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [session_id: "session_abc123"])
      {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.session_id == "session_abc123"
    end

    @tag :fast
    test "delegation can bind to session when parent is unbound" do
      {:ok, cap} = Capability.new(@valid_attrs)
      {:ok, child} = Capability.delegate(cap, "agent_worker001", session_id: "session_new")
      assert child.session_id == "session_new"
    end

    @tag :fast
    test "delegation cannot unbind from parent session" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [session_id: "session_abc123"])
      # Parent's session_id is inherited (can't pass nil to unbind)
      {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.session_id == "session_abc123"
    end
  end

  # ── 2.2 Task-Bound Capabilities ─────────────────────────────────

  describe "task-bound capabilities" do
    @tag :fast
    test "capabilities are not task-bound by default" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert cap.task_id == nil
    end

    @tag :fast
    test "can create task-bound capability" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [task_id: "task_pipeline_001"])
      assert cap.task_id == "task_pipeline_001"
    end

    @tag :fast
    test "unbound capability matches any task" do
      {:ok, cap} = Capability.new(@valid_attrs)
      assert Capability.scope_matches?(cap, task_id: "task_pipeline_001")
    end

    @tag :fast
    test "task-bound capability matches correct task" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [task_id: "task_pipeline_001"])
      assert Capability.scope_matches?(cap, task_id: "task_pipeline_001")
    end

    @tag :fast
    test "task-bound capability rejects wrong task" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [task_id: "task_pipeline_001"])
      refute Capability.scope_matches?(cap, task_id: "task_other")
    end

    @tag :fast
    test "delegation inherits task_id from parent" do
      {:ok, cap} = Capability.new(@valid_attrs ++ [task_id: "task_pipeline_001"])
      {:ok, child} = Capability.delegate(cap, "agent_worker001")
      assert child.task_id == "task_pipeline_001"
    end

    @tag :fast
    test "delegation can bind to task when parent is unbound" do
      {:ok, cap} = Capability.new(@valid_attrs)
      {:ok, child} = Capability.delegate(cap, "agent_worker001", task_id: "task_sub")
      assert child.task_id == "task_sub"
    end
  end

  # ── Combined scope binding ──────────────────────────────────────

  describe "combined scope binding" do
    @tag :fast
    test "dual-bound capability requires both session and task match" do
      {:ok, cap} = Capability.new(
        @valid_attrs ++ [session_id: "session_abc", task_id: "task_001"]
      )

      assert Capability.scope_matches?(cap, session_id: "session_abc", task_id: "task_001")
      refute Capability.scope_matches?(cap, session_id: "session_abc", task_id: "task_other")
      refute Capability.scope_matches?(cap, session_id: "session_other", task_id: "task_001")
      refute Capability.scope_matches?(cap, session_id: "session_abc")
      refute Capability.scope_matches?(cap, task_id: "task_001")
    end

    @tag :fast
    test "session_id and task_id in signing payload" do
      {:ok, cap1} = Capability.new(@valid_attrs ++ [id: "cap_same"])
      {:ok, cap2} = Capability.new(@valid_attrs ++ [id: "cap_same", session_id: "sess_x"])
      {:ok, cap3} = Capability.new(@valid_attrs ++ [id: "cap_same", task_id: "task_x"])

      refute Capability.signing_payload(cap1) == Capability.signing_payload(cap2)
      refute Capability.signing_payload(cap1) == Capability.signing_payload(cap3)
      refute Capability.signing_payload(cap2) == Capability.signing_payload(cap3)
    end

    @tag :fast
    test "worker subagent pattern: session + task + max_uses + depth 0" do
      {:ok, parent} = Capability.new(
        @valid_attrs ++ [session_id: "session_main"]
      )

      {:ok, worker_cap} = Capability.delegate(parent, "agent_worker001",
        task_id: "task_deploy_staging",
        max_uses: 1,
        delegation_depth: 0
      )

      # Worker cap has all the isolation properties
      assert worker_cap.session_id == "session_main"
      assert worker_cap.task_id == "task_deploy_staging"
      assert worker_cap.max_uses == 1
      assert worker_cap.delegation_depth == 0

      # Can't re-delegate
      assert {:error, :delegation_depth_exhausted} =
               Capability.delegate(worker_cap, "agent_other")

      # Scope matches correct context
      assert Capability.scope_matches?(worker_cap,
               session_id: "session_main",
               task_id: "task_deploy_staging"
             )

      # Scope rejects wrong context
      refute Capability.scope_matches?(worker_cap,
               session_id: "session_main",
               task_id: "task_other"
             )
    end
  end
end
