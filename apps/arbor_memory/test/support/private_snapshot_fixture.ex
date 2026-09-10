Code.require_file("../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)

defmodule Arbor.Memory.Test.PrivateSnapshotFixture do
  @moduledoc """
  Isolated, synchronous private-snapshot fixtures with actual disk-backed owners.

  Call from an `async: false` test in the isolated test runtime. The fixture owns
  its temporary directory and replacement stores; it restores any Memory
  supervisor child it displaced and Security's canonical test tree on exit.
  Admissions belong to the calling process, so Session tests pass `receipt!/1`
  to Session instead of passing an admission created by the test process.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security
  alias Arbor.Security.{AuthorityStore, SystemAuthority}

  @memory_name :arbor_memory_durable
  @root_name :arbor_security_signing_keys
  @root_prefix "arbor_private_snapshot_"

  defmodule DiskBackend do
    @moduledoc false
    # JSONFile supplies actual disk persistence and atomic Record fences. This
    # test-only query adapter adds the inventory operation BufferedStore needs;
    # its list/get calls run synchronously inside the same BufferedStore owner.
    alias Arbor.Security.Store.JSONFile

    defdelegate put(key, value, opts), to: JSONFile
    defdelegate get(key, opts), to: JSONFile
    defdelegate delete(key, opts), to: JSONFile
    defdelegate list(opts), to: JSONFile
    defdelegate compare_and_swap(key, expected, replacement, opts), to: JSONFile
    defdelegate compare_and_delete(key, expected, opts), to: JSONFile
    defdelegate durability_class(opts), to: JSONFile

    def query(_filter, opts) do
      with {:ok, keys} <- JSONFile.list(opts) do
        Enum.reduce_while(Enum.sort(keys), {:ok, []}, fn key, {:ok, records} ->
          case JSONFile.get(key, opts) do
            {:ok, record} -> {:cont, {:ok, [record | records]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          error -> error
        end
      end
    end
  end

  def start!(opts \\ []) do
    root =
      Path.expand(
        Path.join(
          System.tmp_dir!(),
          @root_prefix <> to_string(System.unique_integer([:positive]))
        )
      )

    previous_memory = memory_child!()
    previous_mode = Application.fetch_env(:arbor_security, :system_authority_mode)
    previous_key = Application.fetch_env(:arbor_security, :master_key_path)
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    Process.unlink(supervisor)

    on_exit(fn ->
      stop_system_authority!()
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      restore_memory_child!(previous_memory)
      restore_env(:system_authority_mode, previous_mode)
      restore_env(:master_key_path, previous_key)
      assert :ok = Security.TestBootstrap.restore_supervised_tree!()
      assert Path.dirname(root) == Path.expand(System.tmp_dir!())
      assert String.starts_with?(Path.basename(root), @root_prefix)
      File.rm_rf!(root)
    end)

    remove_memory_child!(previous_memory)
    stop_system_authority!()
    remove_root_store!()
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    Application.put_env(:arbor_security, :master_key_path, Path.join(root, "master.key"))

    root_opts = [
      name: @root_name,
      backend: Arbor.Security.Store.JSONFile,
      backend_opts: [base_dir: Path.join(root, "signing")],
      namespace: "signing_keys",
      hydration_limit: 100
    ]

    store_opts = [
      name: @memory_name,
      backend: Keyword.get(opts, :backend, DiskBackend),
      backend_opts:
        Keyword.put(Keyword.get(opts, :backend_opts, []), :base_dir, Path.join(root, "memory")),
      collection: "private_snapshots",
      write_mode: :sync,
      ack_mode: :backend,
      hydration_limit: 1_000
    ]

    assert {:ok, _} = Supervisor.start_child(supervisor, {AuthorityStore, root_opts})

    assert {:ok, _} =
             Supervisor.start_child(
               supervisor,
               Supervisor.child_spec({BufferedStore, store_opts}, id: @memory_name)
             )

    assert {:ok, _} = Supervisor.restart_child(Arbor.Security.Supervisor, SystemAuthority)
    %{root: root, store_opts: store_opts, supervisor: supervisor}
  end

  def owner!(agent \\ nil, human \\ nil) do
    agent = agent || new_agent!()
    human = human || new_human!()

    %{
      agent: agent,
      human: human,
      read_cap: grant!(agent.agent_id, "arbor://memory/read/" <> agent.agent_id),
      write_cap: grant!(agent.agent_id, "arbor://memory/write/" <> agent.agent_id),
      chat_cap: grant!(human.agent_id, "arbor://chat/agent/" <> agent.agent_id)
    }
  end

  def receipt!(owner) do
    assert {:ok, signed} =
             SignedRequest.sign("authorize", owner.human.agent_id, owner.human.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(
               owner.human.agent_id,
               "arbor://chat/agent/" <> owner.agent.agent_id,
               :chat,
               signed_request: signed
             )

    receipt
  end

  def admission!(owner, opts \\ []) do
    assert {:ok, admission} =
             Security.exchange_private_memory_receipt(
               receipt!(owner),
               owner.agent.agent_id,
               owner.human.agent_id,
               %{
                 session_id: Keyword.get(opts, :session_id, "private-snapshot-session"),
                 turn_id:
                   Keyword.get_lazy(opts, :turn_id, fn ->
                     "private-snapshot-turn-#{System.unique_integer([:positive])}"
                   end)
               }
             )

    assert :ok =
             Security.activate_private_memory_admission(
               admission,
               Keyword.get(opts, :engagement_id, "private-snapshot-engagement")
             )

    admission
  end

  def restart_store!(fixture) do
    assert :ok = Supervisor.terminate_child(fixture.supervisor, @memory_name)
    assert {:ok, _} = Supervisor.restart_child(fixture.supervisor, @memory_name)
    :ok
  end

  def restart_root!(fixture) do
    stop_system_authority!()
    assert :ok = Supervisor.terminate_child(fixture.supervisor, @root_name)
    assert {:ok, _} = Supervisor.restart_child(fixture.supervisor, @root_name)
    assert {:ok, _} = Supervisor.restart_child(Arbor.Security.Supervisor, SystemAuthority)
    :ok
  end

  defp new_agent! do
    assert {:ok, identity} = Identity.generate()
    assert :ok = Security.register_identity(identity)
    on_exit(fn -> Security.deregister_identity(identity.agent_id) end)
    identity
  end

  defp new_human! do
    fixture = Arbor.Security.OIDCTestHelper.issue_identity()

    assert :ok =
             Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)

    on_exit(fn ->
      fixture.cleanup.()
      Security.deregister_identity(fixture.identity.agent_id)
    end)

    fixture.identity
  end

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)
    on_exit(fn -> Security.revoke(cap.id) end)
    cap
  end

  defp memory_child! do
    case Process.whereis(@memory_name) do
      nil ->
        nil

      pid ->
        case Enum.find(Supervisor.which_children(Arbor.Memory.Supervisor), fn
               {_id, child, _type, _modules} -> child == pid
             end) do
          {id, ^pid, :worker, [BufferedStore]} ->
            assert {:ok, spec} = :supervisor.get_childspec(Arbor.Memory.Supervisor, id)
            spec

          _ ->
            raise "private snapshot fixture refuses an unowned Memory authority"
        end
    end
  end

  defp remove_memory_child!(nil), do: :ok

  defp remove_memory_child!(%{id: id}) do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, id)
    assert :ok = Supervisor.delete_child(Arbor.Memory.Supervisor, id)
  end

  defp restore_memory_child!(nil), do: :ok

  defp restore_memory_child!(spec) do
    assert {:ok, _} = Supervisor.start_child(Arbor.Memory.Supervisor, spec)
  end

  defp stop_system_authority! do
    case Supervisor.terminate_child(Arbor.Security.Supervisor, SystemAuthority) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp remove_root_store! do
    assert :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, @root_name)
    assert :ok = Supervisor.delete_child(Arbor.Security.Supervisor, @root_name)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_security, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_security, key)
end
