defmodule Mix.Tasks.Arbor.Coding.ReconcileTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Arbor.Coding.Reconcile

  @moduletag :fast

  test "defaults to live-node RPC and passes only fixed reconciliation options" do
    report = %{"mode" => "dry_run", "manifest_sha256" => String.duplicate("a", 64)}

    rpc_call = fn node, module, function, [opts], timeout ->
      send(self(), {:rpc, node, module, function, opts, timeout})
      {:ok, report}
    end

    assert {:ok, ^report} =
             Reconcile.execute(
               ["--caller-id", "operator-1", "--task-id", "task-1"],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc_call
             )

    assert_receive {:rpc, :arbor_test@localhost, Arbor.Orchestrator, :reconcile_coding_resources,
                    opts, 5_000}

    assert opts == [caller_id: "operator-1", task_id: "task-1", principal_id: nil, max_items: 64]
    refute Keyword.has_key?(opts, :apply)
  end

  test "default mode fails clearly when no live node is available" do
    assert {:error, %{"field" => "live", "error" => "target_unavailable"}} =
             Reconcile.execute(
               ["--caller-id", "operator-1"],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> false end,
               target_node: fn -> :arbor_test@localhost end,
               reconciler: fn _opts -> send(self(), :unexpected_local_fallback) end
             )

    refute_received :unexpected_local_fallback
  end

  test "local mode is explicit and apply remains unsupported" do
    report = %{"mode" => "dry_run"}

    assert {:ok, ^report} =
             Reconcile.execute(
               ["--local", "--caller-id", "operator-1"],
               reconciler: fn opts ->
                 send(self(), {:local, opts})
                 {:ok, report}
               end
             )

    assert_receive {:local,
                    [caller_id: "operator-1", task_id: nil, principal_id: nil, max_items: 64]}

    assert {:error, %{"field" => "mode", "error" => "apply_unsupported"}} =
             Reconcile.execute(["--caller-id", "operator-1", "--apply"])

    assert {:error, %{"field" => "mode", "error" => "dry_run_required"}} =
             Reconcile.execute(["--caller-id", "operator-1", "--no-dry-run"])
  end

  test "rejects executable selectors and unexpected positional input" do
    assert {:error, %{"field" => "arguments", "error" => "unexpected_positional_argument"}} =
             Reconcile.execute(["--caller-id", "operator-1", "Arbor.Orchestrator"])

    assert {:error, %{"field" => "arguments", "error" => "unknown_or_invalid_option"}} =
             Reconcile.execute(["--caller-id", "operator-1", "--module", "Evil"])
  end
end
