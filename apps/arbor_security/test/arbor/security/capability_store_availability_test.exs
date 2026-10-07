defmodule Arbor.Security.CapabilityStoreAvailabilityTest do
  @moduledoc """
  Isolated availability regressions for VP-05D2A0. These temporarily terminate
  exact supervised authority children, so they must remain synchronous and run
  outside a live development node.
  """

  use ExUnit.Case, async: false

  alias Arbor.Security.{CapabilityStore, SystemAuthority, TestBootstrap}

  setup do
    previous = Application.get_env(:arbor_security, :egress_gate_enforcing)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_security, :egress_gate_enforcing)
      else
        Application.put_env(:arbor_security, :egress_gate_enforcing, previous)
      end
    end)

    :ok
  end

  @tag spec: "VP-05D2A0"
  test "security regression: unavailable CapabilityStore fails egress closed" do
    {ctx, cap} = issue_disclosure!()

    without_supervised_child(CapabilityStore, fn ->
      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(
                 ctx.agent_id,
                 :external_provider,
                 authorize_opts(ctx, cap.id)
               )
    end)
  end

  @tag spec: "VP-05D2A0"
  test "security regression: unavailable SystemAuthority verifier fails egress closed" do
    {ctx, cap} = issue_disclosure!()

    without_supervised_child(SystemAuthority, fn ->
      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(
                 ctx.agent_id,
                 :external_provider,
                 authorize_opts(ctx, cap.id)
               )
    end)
  end

  @tag spec: "VP-05D2A0"
  test "security regression: unavailable signer returns an issuance error" do
    ctx = context()

    without_supervised_child(SystemAuthority, fn ->
      assert {:error, :system_authority_unavailable} =
               Arbor.Security.issue_disclosure_capability_fixture(issue_opts(ctx))
    end)
  end

  @tag spec: "VP-05D2A0"
  test "security regression: unavailable store returns an issuance error" do
    ctx = context()

    without_supervised_child(CapabilityStore, fn ->
      assert {:error, :capability_store_unavailable} =
               Arbor.Security.issue_disclosure_capability_fixture(issue_opts(ctx))
    end)
  end

  defp issue_disclosure! do
    ctx = context()
    {:ok, cap} = Arbor.Security.issue_disclosure_capability_fixture(issue_opts(ctx))
    {ctx, cap}
  end

  defp context do
    unique = System.unique_integer([:positive])

    %{
      agent_id: Arbor.Identifiers.generate_agent_id(),
      session_id: "session_availability_#{unique}",
      task_id: "task_availability_#{unique}",
      principal_scope: "human_availability_#{unique}"
    }
  end

  defp issue_opts(ctx) do
    [
      principal_id: ctx.agent_id,
      session_id: ctx.session_id,
      task_id: ctx.task_id,
      principal_scope: ctx.principal_scope,
      destination: "api.example.com",
      provider: "future_provider",
      runtime: "arbor"
    ]
  end

  defp authorize_opts(ctx, capability_id) do
    [
      session_id: ctx.session_id,
      task_id: ctx.task_id,
      principal_scope: ctx.principal_scope,
      egress_taint: :untrusted,
      disclosure_capability_id: capability_id,
      egress_destination: "api.example.com",
      egress_provider: "future_provider",
      egress_runtime: "arbor"
    ]
  end

  defp without_supervised_child(child_id, fun) do
    supervisor = Process.whereis(Arbor.Security.Supervisor)
    assert is_pid(supervisor)
    pid = supervised_child_pid(supervisor, child_id)
    assert Process.whereis(child_id) == pid
    assert :ok = Supervisor.terminate_child(supervisor, child_id)
    assert Process.whereis(child_id) == nil

    try do
      fun.()
    after
      assert :ok = TestBootstrap.restore_supervised_tree!()
    end

    replacement = supervised_child_pid(supervisor, child_id)
    assert is_pid(replacement)
    assert Process.whereis(child_id) == replacement
  end

  defp supervised_child_pid(supervisor, child_id) do
    Enum.find_value(Supervisor.which_children(supervisor), fn
      {^child_id, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end
end
