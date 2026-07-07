defmodule Arbor.Orchestrator.ActionsExecutorFileWorkspaceTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Security

  setup do
    start_security_and_trust()

    {:ok, identity} = Identity.generate(name: "actions-executor-file-workspace")
    agent_id = identity.agent_id
    :ok = Security.register_identity(identity)

    repo_root = repo_root()
    repo_scope = "arbor://fs/read/#{String.trim_leading(repo_root, "/")}/**"

    {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")
    {:ok, _} = Security.grant(principal: agent_id, resource: repo_scope)

    create_profile_with_rules(agent_id, :block, %{"arbor://fs/read" => :allow})

    on_exit(fn ->
      case Security.list_capabilities(agent_id) do
        {:ok, caps} -> Enum.each(caps, &Security.revoke(&1.id))
        _ -> :ok
      end

      if Process.whereis(Arbor.Trust.Manager) do
        Arbor.Trust.Manager.delete_trust_profile(agent_id)
      end
    end)

    %{agent_id: agent_id, identity: identity, repo_root: repo_root}
  end

  test "file_read resolves relative paths against the tool workdir before authorization", %{
    agent_id: agent_id,
    identity: identity,
    repo_root: repo_root
  } do
    signer = Security.make_signer(agent_id, identity.private_key)
    relative_path = "apps/arbor_agent/priv/templates/test_agent.md"

    assert {:ok, output} =
             ActionsExecutor.execute("file_read", %{"path" => relative_path}, repo_root,
               agent_id: agent_id,
               signer: signer
             )

    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["path"] == Path.join(repo_root, relative_path)
    assert decoded["content"] =~ ~s(name: "test_agent")
  end

  test "security regression: file_read denies absolute paths outside the tool workdir", %{
    agent_id: agent_id,
    identity: identity,
    repo_root: repo_root
  } do
    signer = Security.make_signer(agent_id, identity.private_key)
    outside_path = tmp_probe_path("outside-read")
    File.write!(outside_path, "outside")
    on_exit(fn -> File.rm(outside_path) end)

    assert {:error, message} =
             ActionsExecutor.execute("file_read", %{"path" => outside_path}, repo_root,
               agent_id: agent_id,
               signer: signer
             )

    assert denial_message?(message)
  end

  test "security regression: file_read denies relative traversal outside the tool workdir", %{
    agent_id: agent_id,
    identity: identity,
    repo_root: repo_root
  } do
    signer = Security.make_signer(agent_id, identity.private_key)
    outside_path = tmp_probe_path("traversal-read")
    File.write!(outside_path, "outside")
    on_exit(fn -> File.rm(outside_path) end)

    traversal_path = Path.relative_to(outside_path, repo_root)

    assert {:error, message} =
             ActionsExecutor.execute("file_read", %{"path" => traversal_path}, repo_root,
               agent_id: agent_id,
               signer: signer
             )

    assert denial_message?(message)
  end

  test "security regression: file_glob without base_path cannot enumerate outside workdir", %{
    agent_id: agent_id,
    identity: identity,
    repo_root: repo_root
  } do
    signer = Security.make_signer(agent_id, identity.private_key)
    outside_path = tmp_probe_path("glob")
    File.write!(outside_path, "outside")
    on_exit(fn -> File.rm(outside_path) end)

    assert {:error, message} =
             ActionsExecutor.execute("file_glob", %{"pattern" => outside_path}, repo_root,
               agent_id: agent_id,
               signer: signer
             )

    assert message =~ "relative" or denial_message?(message)
  end

  defp start_security_and_trust do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.Identity.NonceCache)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)
    ensure_started(Arbor.Security.Constraint.RateLimiter)

    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  defp create_profile_with_rules(agent_id, baseline, rules) do
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
    end

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: baseline, rules: rules}
    end)
  end

  defp repo_root do
    cwd = File.cwd!() |> Path.expand()

    cond do
      File.exists?(Path.join(cwd, "apps/arbor_agent/priv/templates/test_agent.md")) ->
        cwd

      File.exists?(Path.join(cwd, "../../apps/arbor_agent/priv/templates/test_agent.md")) ->
        Path.expand("../..", cwd)

      true ->
        cwd
    end
    |> String.trim_trailing("/")
  end

  defp tmp_probe_path(label) do
    Path.join(
      System.tmp_dir!(),
      "arbor_actions_executor_#{label}_#{System.unique_integer([:positive])}.txt"
    )
  end

  defp denial_message?(message) when is_binary(message) do
    String.contains?(message, "unauthorized") or
      String.contains?(message, "Path traversal denied") or
      String.contains?(message, "no_capability")
  end
end
