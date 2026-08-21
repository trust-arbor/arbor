defmodule Mix.Tasks.Arbor.ApproveTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Mix.Tasks.Arbor.Approve

  @caller "agent_operator"
  @target :arbor_test@localhost

  test "security regression: answers through the authorized orchestration facade" do
    test_pid = self()

    rpc = fn node, module, function, args, timeout ->
      send(test_pid, {:rpc, node, module, function, args, timeout})
      :ok
    end

    id = "irq_design_" <> String.duplicate("a", 64)

    assert {:ok, message} =
             Approve.execute(
               [id, "--basis", "reviewed in the isolated worktree"],
               runtime_opts(rpc)
             )

    assert message == "approve: #{id}"

    assert_receive {:rpc, @target, Arbor.Agent.Orchestration, :answer_approval,
                    [
                      ^id,
                      :approve,
                      [caller_id: @caller, note: "reviewed in the isolated worktree"]
                    ], 15_000}
  end

  test "rejects unknown options and extra positional arguments before any RPC" do
    rpc = fn _node, _module, _function, _args, _timeout ->
      send(self(), :rpc_called)
      :ok
    end

    assert {:error, message} =
             Approve.execute(["irq_deadbeef", "--rejcet"], runtime_opts(rpc))

    assert message =~ "unknown or invalid option"

    assert {:error, "expected exactly one approval request id"} =
             Approve.execute(["irq_deadbeef", "irq_cafebabe"], runtime_opts(rpc))

    refute_received :rpc_called
  end

  test "rejects conflicting list mode before any RPC" do
    rpc = fn _node, _module, _function, _args, _timeout ->
      send(self(), :rpc_called)
      :ok
    end

    assert {:error, message} =
             Approve.execute(["--list", "--reject"], runtime_opts(rpc))

    assert message =~ "--list cannot be combined"
    refute_received :rpc_called
  end

  test "lists through the authorized orchestration facade" do
    test_pid = self()

    rpc = fn node, module, function, args, timeout ->
      send(test_pid, {:rpc, node, module, function, args, timeout})

      {:ok,
       [
         %{
           id: "irq_deadbeef",
           source: :interaction,
           resource_uri: "arbor://shell/exec",
           description: "Run focused tests"
         }
       ]}
    end

    assert {:ok, output} = Approve.execute(["--list"], runtime_opts(rpc))
    assert output =~ "irq_deadbeef  interaction  arbor://shell/exec"

    assert_receive {:rpc, @target, Arbor.Agent.Orchestration, :list_pending_approvals,
                    [[caller_id: @caller]], 15_000}
  end

  test "propagates capability denial without falling back to Comms" do
    rpc = fn _node, module, function, _args, _timeout ->
      assert module == Arbor.Agent.Orchestration
      assert function == :answer_approval
      {:error, {:unauthorized, :approval_answer_required}}
    end

    assert {:error, message} =
             Approve.execute(["irq_deadbeef", "--reject"], runtime_opts(rpc))

    assert message =~ "approval_answer_required"
  end

  test "validates basis and opaque approval ids with shared contract bounds" do
    rpc = fn _node, _module, _function, _args, _timeout ->
      send(self(), :rpc_called)
      :ok
    end

    assert {:error, message} = Approve.execute(["bad id"], runtime_opts(rpc))
    assert message =~ "not a valid approval id"

    assert {:error, message} =
             Approve.execute(
               ["irq_deadbeef", "--basis", String.duplicate("x", 513)],
               runtime_opts(rpc)
             )

    assert message =~ "exceeds 512 bytes"
    refute_received :rpc_called
  end

  test "resolves the caller from the private key file and checks an explicit claim" do
    tmp = Path.join(System.tmp_dir!(), "arbor_approve_#{System.unique_integer([:positive])}")
    key_path = Path.join(tmp, "caller.key")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, ^key_path} =
             Arbor.Security.write_key_file(key_path, %{
               agent_id: @caller,
               private_key: :crypto.strong_rand_bytes(32)
             })

    test_pid = self()

    rpc = fn _node, _module, _function, [_id, _decision, opts], _timeout ->
      send(test_pid, {:caller_opts, opts})
      :ok
    end

    opts = live_runtime_opts(rpc)

    assert {:ok, _message} =
             Approve.execute(
               ["irq_deadbeef", "--key-file", key_path, "--as", @caller],
               opts
             )

    assert_receive {:caller_opts, [caller_id: @caller, note: nil]}

    assert {:error, mismatch} =
             Approve.execute(
               ["irq_deadbeef", "--key-file", key_path, "--as", "agent_someone_else"],
               opts
             )

    assert mismatch =~ "principal_mismatch"
  end

  defp runtime_opts(rpc) do
    [
      caller_resolver: fn cli ->
        assert cli.key_file == Path.expand("~/.arbor/identity.key")
        {:ok, @caller}
      end
    ]
    |> Keyword.merge(live_runtime_opts(rpc))
  end

  defp live_runtime_opts(rpc) do
    [
      ensure_distribution: fn -> :ok end,
      server_running?: fn -> true end,
      target_node: fn -> @target end,
      rpc_call: rpc
    ]
  end
end
