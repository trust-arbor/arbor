defmodule Arbor.Security.CapabilityRollbackPublicSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-010"

  @moduletag :fast
  @moduletag security: :regression

  @security_supervisor Arbor.Security.Supervisor
  @capability_store :arbor_security_capabilities
  @record_auth_key :crypto.hash(:sha256, "capability-rollback-public-security-regression")

  alias Arbor.Security
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.TestBootstrap

  @tag spec: "SSEC-010"
  test "security regression: authenticated pre-revocation bytes cannot resurrect public authority" do
    ctx = isolated_stack_context()
    on_exit(fn -> restore_security_tree_and_remove_fixture(ctx.fixture_root) end)
    replace_capability_stack!(ctx)

    principal = "agent_capability_rollback_public_#{unique_integer()}"
    resource = "arbor://fs/read/capability-rollback-public-#{unique_integer()}"

    assert {:ok, cap} = Security.grant_fixture(principal: principal, resource: resource)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    record_path = record_path(ctx.authority_root, "capabilities", cap.id)
    pre_revocation_bytes = File.read!(record_path)

    assert %{
             "version" => 3,
             "authentication" => %{
               "algorithm" => "hmac-sha256",
               "key_id" => "master-key-v1",
               "tag" => tag
             }
           } = Jason.decode!(pre_revocation_bytes)

    assert byte_size(tag) == 64
    assert :ok = Security.revoke_fixture(cap.id)

    assert {:error, :unauthorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    revocation_ledger_bytes = File.read!(ctx.revocation_ledger_path)
    File.write!(record_path, pre_revocation_bytes)
    File.chmod!(record_path, 0o600)
    assert File.read!(ctx.revocation_ledger_path) == revocation_ledger_bytes

    restart_capability_stack!(ctx)

    assert {:error, :unauthorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:ok, []} = Security.list_capabilities(principal)
    assert {:error, :not_found} = CapabilityStore.get(cap.id)
  end

  defp isolated_stack_context do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    fixture_root = Path.join(system_tmp, "capability-rollback-public-#{token}")
    File.mkdir!(fixture_root)
    File.chmod!(fixture_root, 0o700)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    authority_root = Path.join(fixture_root, "authority")
    revocation_root = Path.join(fixture_root, "revocation-fence")
    revocation_ledger_path = Path.join(revocation_root, "capability-revocations.json")

    File.mkdir_p!(authority_root)
    File.chmod!(authority_root, 0o700)
    File.mkdir_p!(revocation_root)
    File.chmod!(revocation_root, 0o700)

    %{
      fixture_root: fixture_root,
      authority_root: authority_root,
      revocation_ledger_path: revocation_ledger_path,
      backend_opts: [
        base_dir: authority_root,
        record_auth_key: @record_auth_key,
        revocation_ledger_path: revocation_ledger_path
      ]
    }
  end

  defp replace_capability_stack!(ctx) do
    :ok = Supervisor.terminate_child(@security_supervisor, CapabilityStore)
    :ok = Supervisor.terminate_child(@security_supervisor, @capability_store)
    start_capability_stack!(ctx)
  end

  defp restart_capability_stack!(ctx) do
    stop_named_process(CapabilityStore)
    stop_named_process(@capability_store)
    start_capability_stack!(ctx)
  end

  defp start_capability_stack!(ctx) do
    {:ok, _pid} =
      AuthorityStore.start_test_fixture(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: ctx.backend_opts,
        namespace: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:ok, %{status: :ready}} =
             AuthorityStore.hydration_status(name: @capability_store)

    {:ok, _pid} = CapabilityStore.start_link(test_isolated_owner: true)
  end

  defp restore_security_tree_and_remove_fixture(fixture_root) do
    try do
      TestBootstrap.restore_supervised_tree!()
    after
      File.rm_rf!(fixture_root)
    end
  end

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid when is_pid(pid) -> GenServer.stop(pid)
    end
  end

  defp record_path(root, namespace, key) do
    namespace_digest = digest_hex(<<1, namespace::binary>>)
    key_digest = digest_hex(<<2, key::binary>>)
    Path.join([root, "ns_" <> namespace_digest, key_digest <> ".json"])
  end

  defp digest_hex(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp unique_integer, do: :erlang.unique_integer([:positive])
end
