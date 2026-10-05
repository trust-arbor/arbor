defmodule Arbor.Agent.ProfileNoticeAuthorityOwnerSecurityRegressionTest.Backend do
  @behaviour Arbor.Contracts.Persistence.Store
  use Agent
  alias Arbor.Contracts.Persistence.Record
  @latch {__MODULE__, :latch}
  @failure {__MODULE__, :failure}

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def hold_next(observer), do: :persistent_term.put(@latch, {observer, make_ref()})
  def fail(operation), do: :persistent_term.put(@failure, operation)

  def clear do
    :persistent_term.erase(@latch)
    :persistent_term.erase(@failure)
  end

  def raw(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

  @impl true
  def put(key, %Record{} = record, _) do
    maybe_hold(:put)

    if failing?(:put) do
      {:error, :backend_refused}
    else
      Agent.update(__MODULE__, fn state ->
        record =
          if failing?(:wrong_confirmed_data),
            do: %{record | data: Map.put(record.data, "display_name", "wrong backend value")},
            else: record

        old = state[key]
        now = DateTime.utc_now()

        stored = %{
          record
          | generation: if(old, do: old.generation, else: 1),
            revision: if(old, do: old.revision + 1, else: 1),
            inserted_at: now,
            updated_at: now
        }

        Map.put(state, key, stored)
      end)
    end
  end

  @impl true
  def get(key, _) do
    case raw(key) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @impl true
  def delete(key, _) do
    maybe_hold(:delete)

    if failing?(:delete),
      do: {:error, :backend_refused},
      else: Agent.update(__MODULE__, &Map.delete(&1, key))
  end

  @impl true
  def list(_), do: {:ok, Agent.get(__MODULE__, &Map.keys/1)}
  @impl true
  def exists?(key, _), do: not is_nil(raw(key))
  @impl true
  def durability_class(_), do: :node_restart
  @impl true
  def compare_and_swap(key, expected, replacement, _) do
    maybe_hold(:cas)

    if failing?(:cas) do
      {:error, :backend_refused}
    else
      Agent.get_and_update(__MODULE__, fn state ->
        case {state[key], expected} do
          {nil, :not_found} ->
            now = DateTime.utc_now()
            row = %{replacement | generation: 1, revision: 1, inserted_at: now, updated_at: now}
            {{:ok, row}, Map.put(state, key, row)}

          {%Record{} = old, {:value, observed}}
          when old.generation == observed.generation and old.revision == observed.revision ->
            row = %{
              replacement
              | generation: old.generation,
                revision: old.revision + 1,
                inserted_at: old.inserted_at,
                updated_at: DateTime.utc_now()
            }

            {{:ok, row}, Map.put(state, key, row)}

          _ ->
            {{:error, :conflict}, state}
        end
      end)
    end
  end

  defp failing?(operation), do: :persistent_term.get(@failure, nil) == operation

  defp maybe_hold(operation) do
    case :persistent_term.get(@latch, nil) do
      {observer, ref} ->
        :persistent_term.erase(@latch)
        send(observer, {:backend_entered, operation, self(), ref})

        receive do
          {:release_backend, ^ref} -> :ok
        after
          3_000 -> raise "bounded backend latch expired"
        end

      nil ->
        :ok
    end
  end
end

defmodule Arbor.Agent.ProfileNoticeAuthorityOwnerSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression
  alias Arbor.Agent.{Character, Profile, ProfileStore}
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security
  alias __MODULE__.Backend

  # Trusted same-library source adapter for the ownership/fencing protocol;
  # this is not an actual Session/Heartbeat topology acceptance claim.
  defmodule ProfileSource do
    @behaviour Arbor.Security.Contracts.NativeNoticeSourceAuthorizer
    def acquire(principal, owner) do
      with {:ok, record} <- ProfileStore.notice_authority_snapshot(principal),
           [_ | _] = mailboxes <- record.data["notice_mailboxes"] do
        {:ok,
         %{
           principal_id: principal,
           owner_pid: owner,
           branch_pid: owner,
           role: :session,
           mailboxes: mailboxes
         }}
      else
        _ -> {:error, :native_notice_source_required}
      end
    end

    def recheck(_, _, _), do: :ok
  end

  setup do
    start_supervised!(Backend)

    start_supervised!(
      {BufferedStore,
       name: :arbor_agent_profiles, backend: Backend, write_mode: :sync, ack_mode: :backend}
    )

    Backend.clear()
    previous = Application.fetch_env(:arbor_security, :native_notice_source_authorizer)
    Application.put_env(:arbor_security, :native_notice_source_authorizer, ProfileSource)
    dir = Path.join(System.tmp_dir!(), "notice_profile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old_dir = Application.fetch_env(:arbor_agent, :legacy_agents_dir)
    Application.put_env(:arbor_agent, :legacy_agents_dir, dir)

    on_exit(fn ->
      Backend.clear()
      restore(:arbor_security, :native_notice_source_authorizer, previous)
      restore(:arbor_agent, :legacy_agents_dir, old_dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "security regression: broker and lane restart cannot pin a pre-revocation profile" do
    for ordering <- [:broker_only, :lane_then_broker, :broker_then_lane] do
      {:ok, identity} = Identity.generate(name: "profile-notice-restart")
      :ok = Security.register_identity(Identity.public_only(identity))
      :ok = Security.store_signing_key(identity.agent_id, identity.private_key)
      profile = profile(identity.agent_id)
      assert :ok = ProfileStore.store_profile(profile)
      assert {:ok, old_source} = open_source(identity)
      assert is_reference(old_source)
      Backend.hold_next(self())
      writer = Task.async(fn -> ProfileStore.store_profile(%{profile | notice_mailboxes: []}) end)
      assert_receive {:backend_entered, :put, backend_owner, latch}, 1_000
      assert backend_owner == Process.whereis(:arbor_agent_profiles)

      try do
        case ordering do
          :broker_only ->
            restart_broker()

          :lane_then_broker ->
            restart_lane()
            restart_broker()

          :broker_then_lane ->
            restart_broker()
            restart_lane()
        end

        # Acquisition uses a new genuine owner-bound SigningAuthority. Its
        # authoritative snapshot queues behind the already-owned mutation.
        probe = Task.async(fn -> open_source(identity) end)
        probe_ref = probe.ref
        refute_receive {^probe_ref, _}, 50
        send(backend_owner, {:release_backend, latch})
        assert {:error, :native_notice_source_required} = Task.await(probe, 2_000)
        result = Task.await(writer, 2_000)
        assert result in [:ok, {:error, :outcome_unknown}]
        assert {:ok, record} = ProfileStore.notice_authority_snapshot(identity.agent_id)
        assert record.data["notice_mailboxes"] == []
        assert Backend.raw(identity.agent_id).data["notice_mailboxes"] == []
      after
        send(backend_owner, {:release_backend, latch})
        Security.delete_signing_key(identity.agent_id)
        Security.deregister_identity(identity.agent_id)
      end
    end
  end

  test "security regression: delete and CAS snapshots share the fixed owner lane" do
    profile = profile("agent_profile_notice_delete_cas")
    assert :ok = ProfileStore.store_profile(profile)
    assert {:ok, observed} = ProfileStore.authority_mutation_snapshot(profile.agent_id)

    governed = %{
      "template" => "new",
      "initial_capabilities" => [],
      "template_authority_policy" => %{},
      "template_source" => "fixture"
    }

    # Invalid closed mutation still refuses without entering an arbitrary write.
    assert {:error, _} = ProfileStore.apply_authority_mutation(observed, governed)

    assert {:error, :authority_unavailable} =
             ProfileStore.apply_owned_profile_operation(:store, profile)

    assert {:error, :authority_unavailable} =
             ProfileStore.apply_owned_profile_operation(:delete, profile.agent_id)

    Backend.hold_next(self())
    writer = Task.async(fn -> ProfileStore.delete_profile(profile.agent_id) end)
    assert_receive {:backend_entered, :delete, backend_owner, latch}, 1_000
    restart_broker()
    snapshot = Task.async(fn -> ProfileStore.notice_authority_snapshot(profile.agent_id) end)
    snapshot_ref = snapshot.ref
    refute_receive {^snapshot_ref, _}, 50
    send(backend_owner, {:release_backend, latch})
    assert :ok = Task.await(writer)
    assert {:error, :not_found} = Task.await(snapshot)
  end

  test "security regression: acknowledged CAS retires the old source before backend IO" do
    {:ok, identity} = Identity.generate(name: "profile-notice-cas")
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)
    profile = profile(identity.agent_id)
    assert :ok = ProfileStore.store_profile(profile)
    assert {:ok, old_source} = open_source(identity)
    assert {:ok, observed} = ProfileStore.authority_mutation_snapshot(identity.agent_id)
    capabilities = []
    source = %{"name" => "new", "layer" => "shipped"}

    template = %{
      "name" => "new",
      "required_capabilities" => capabilities,
      "trust_preset" => %{"baseline" => "block", "rules" => %{}},
      "template_source" => source
    }

    {:ok, policy} = Arbor.Agent.TemplateAuthorityPolicy.build("new", template)

    governed = %{
      "template" => "new",
      "initial_capabilities" => capabilities,
      "metadata" => %{"template_authority_policy" => policy, "template_source" => source}
    }

    Backend.hold_next(self())
    writer = Task.async(fn -> ProfileStore.apply_authority_mutation(observed, governed) end)
    assert_receive {:backend_entered, :cas, backend_owner, latch}, 1_000
    assert backend_owner == Process.whereis(:arbor_agent_profiles)

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    try do
      assert {:error, :native_notice_source_required} =
               Security.delegate_native_notice_worker(old_source, worker)

      restart_broker()
      probe = Task.async(fn -> open_source(identity) end)
      probe_ref = probe.ref
      refute_receive {^probe_ref, _}, 50
      send(backend_owner, {:release_backend, latch})
      assert {:ok, %{outcome: :applied}} = Task.await(writer)
      assert {:ok, successor} = Task.await(probe)
      assert successor != old_source
      assert Backend.raw(identity.agent_id).data["template"] == "new"
      assert {:ok, snapshot} = ProfileStore.notice_authority_snapshot(identity.agent_id)
      assert snapshot.data["template"] == "new"
    after
      send(backend_owner, {:release_backend, latch})
      send(worker, :stop)
      Security.delete_signing_key(identity.agent_id)
      Security.deregister_identity(identity.agent_id)
    end
  end

  test "durability regression: a different acknowledged record is not successful profile storage" do
    profile = profile("agent_profile_notice_wrong_confirmation")
    Backend.fail(:wrong_confirmed_data)
    assert {:error, :outcome_unknown} = ProfileStore.store_profile(profile)
    assert Backend.raw(profile.agent_id).data["display_name"] == "wrong backend value"
  end

  test "durability regression: unconfirmed lazy migration and delete retain the legacy file", c do
    profile = profile("agent_profile_notice_legacy")
    path = Path.join(c.dir, profile.agent_id <> ".agent.json")
    File.write!(path, Profile.to_json(profile) |> elem(1))
    Backend.fail(:cas)
    assert {:ok, _} = ProfileStore.load_profile(profile.agent_id)
    assert File.exists?(path)
    assert {:ok, 0} = ProfileStore.migrate_json_profiles()
    assert File.exists?(path)
    Backend.fail(:delete)
    assert {:error, :outcome_unknown} = ProfileStore.delete_profile(profile.agent_id)
    assert File.exists?(path)
    Backend.clear()
    assert :ok = ProfileStore.store_profile(profile)
    assert :ok = ProfileStore.delete_profile(profile.agent_id)
    refute File.exists?(path)
  end

  defp profile(principal) do
    %Profile{
      agent_id: principal,
      display_name: "Notice",
      character: Character.new(name: "Notice"),
      created_at: DateTime.utc_now(),
      version: 1,
      notice_mailboxes: [
        %{
          "mailbox_id" => "owner",
          "recipient_subject_id" => "human_notice_profile",
          "owner_id" => "human_notice_profile",
          "engagement_id" => "eng_" <> String.duplicate("c", 32)
        }
      ]
    }
  end

  defp open_source(identity) do
    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    Security.open_native_notice_source(authority)
  end

  defp restart_broker do
    supervisor = Arbor.Security.Supervisor
    assert :ok = Supervisor.terminate_child(supervisor, Arbor.Security.NativeNoticeBroker)
    assert {:ok, _} = Supervisor.restart_child(supervisor, Arbor.Security.NativeNoticeBroker)
  end

  defp restart_lane do
    supervisor = Arbor.Agent.AppSupervisor
    assert :ok = Supervisor.terminate_child(supervisor, Arbor.Agent.ProfileAuthorityOwner)
    assert {:ok, _} = Supervisor.restart_child(supervisor, Arbor.Agent.ProfileAuthorityOwner)
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
