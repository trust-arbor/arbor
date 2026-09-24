defmodule Arbor.Actions.ShellFilesystemContainmentSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Arbor.Actions
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Trust

  setup do
    if Process.whereis(Arbor.Trust.Store) == nil, do: start_supervised!(Arbor.Trust.Store)

    if Process.whereis(Arbor.Trust.Manager) == nil do
      start_supervised!(
        {Arbor.Trust.Manager, circuit_breaker: false, decay: false, event_store: false}
      )
    end

    previous_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)

    on_exit(fn ->
      if is_nil(previous_guard),
        do: Application.delete_env(:arbor_trust, :approval_guard_enabled),
        else: Application.put_env(:arbor_trust, :approval_guard_enabled, previous_guard)
    end)

    root =
      Path.join(
        System.tmp_dir!(),
        "arbor_action_fs_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    :ok = File.mkdir(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    cwd = Path.join(root, "work")
    :ok = File.mkdir(cwd)
    # Only this synthetic directory gets a test-owned write ceiling. Ordinary
    # production fs/write remains :ask; an action's shell approval cannot grant it.
    previous_ceilings = Application.get_env(:arbor_trust, :security_ceilings)

    Application.put_env(
      :arbor_trust,
      :security_ceilings,
      Map.put(previous_ceilings || %{}, "arbor://fs/write#{cwd}", :auto)
    )

    rebind_trust!()

    on_exit(fn ->
      if is_nil(previous_ceilings),
        do: Application.delete_env(:arbor_trust, :security_ceilings),
        else: Application.put_env(:arbor_trust, :security_ceilings, previous_ceilings)

      rebind_trust!()
    end)

    File.write!(Path.join(cwd, "input"), "permitted-data")
    File.write!(Path.join(root, "outside"), "outside-data")
    {:ok, identity} = Security.generate_identity(name: "synthetic-action-containment")
    :ok = Security.register_identity(identity)
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(identity.agent_id)
    :ok = Arbor.Trust.Store.store_profile(profile)

    for resource <- [
          "arbor://shell/exec/cat",
          "arbor://shell/exec/touch",
          "arbor://fs/read#{cwd}",
          "arbor://fs/write#{cwd}"
        ] do
      {:ok, _} = Trust.set_rule(identity.agent_id, resource, :auto)
    end

    {:ok, _} = Security.grant(principal: identity.agent_id, resource: "arbor://shell/exec/**")
    old = Application.get_env(:arbor_shell, :agent_authorizer)
    Application.put_env(:arbor_shell, :agent_authorizer, Actions.Shell)

    on_exit(fn ->
      Application.put_env(:arbor_shell, :agent_authorizer, old)
      {:ok, caps} = Security.list_capabilities(identity.agent_id)
      for cap <- caps, do: Security.revoke(cap.id)
      Security.deregister_identity(identity.agent_id)
      File.rm_rf!(root)
    end)

    %{identity: identity, cwd: cwd, root: root}
  end

  test "security regression: public Actions prepared route cannot read without filesystem authority",
       c do
    assert {:error, _} = execute(c, "cat input")
  end

  test "security regression: public Actions route denies outside filesystem and cannot forge scope",
       c do
    grant(c, :read)

    result =
      execute(c, "cat #{c.root}/outside", %{agent_containment: %{cwd: c.root, write: true}})

    if :os.type() == {:unix, :darwin} do
      assert {:ok, r} = result
      assert r.exit_code != 0
      refute r.stdout =~ "outside-data"
    else
      assert {:error, _} = result
    end
  end

  test "public Actions permitted file read and touch still work on qualified macOS", c do
    grant(c, :read)
    grant(c, :write)

    if :os.type() == {:unix, :darwin} do
      assert {:ok, %{stdout: "permitted-data", exit_code: 0}} = execute(c, "cat input")
      assert {:ok, %{exit_code: 0}} = execute(c, "touch output")
      assert File.regular?(Path.join(c.cwd, "output"))
    else
      assert {:error, _} = execute(c, "touch output")
      refute File.exists?(Path.join(c.cwd, "output"))
    end
  end

  test "filesystem Trust refusal is not overridden by an existing capability", c do
    grant(c, :read)
    {:ok, _} = Trust.set_rule(c.identity.agent_id, "arbor://fs/read#{c.cwd}", :block)
    assert {:error, _} = execute(c, "cat input")
  end

  defp rebind_trust! do
    :ok = Application.stop(:arbor_trust)
    :ok = Arbor.Trust.PolicyHost.release_claim()
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
  end

  defp grant(c, operation) do
    {:ok, _} =
      Security.grant(
        principal: c.identity.agent_id,
        resource: "arbor://fs/#{operation}#{c.cwd}/**"
      )
  end

  defp execute(c, command, extra \\ %{}) do
    resource = "arbor://shell/exec/" <> hd(String.split(command))
    {:ok, proof} = SignedRequest.sign(resource, c.identity.agent_id, c.identity.private_key)

    Actions.authorize_and_execute(
      c.identity.agent_id,
      Actions.Shell.Execute,
      Map.merge(%{command: command, cwd: c.cwd, timeout: 5_000}, extra),
      %{
        agent_id: c.identity.agent_id,
        signed_request: proof,
        approved_invocation: %{
          request_id: "irq_synthetic_shell_containment",
          principal_id: c.identity.agent_id,
          resource_uri: resource,
          decision: :approved
        }
      }
    )
  end
end
