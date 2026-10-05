defmodule Arbor.Orchestrator.NativeNoticeWorkerSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator.NativeNoticeWorker
  alias Arbor.Security

  # Trusted compiled lower source-authorizer fixture. This proves the actual
  # broker/public-facade handoff; actual Branch roles are tested in Agent.
  defmodule SourceAuthority do
    def acquire(principal, owner) do
      {:ok,
       %{
         principal_id: principal,
         owner_pid: owner,
         branch_pid: owner,
         role: :session,
         mailboxes: [
           %{
             "mailbox_id" => "owner",
             "recipient_subject_id" => "human_handoff",
             "owner_id" => "human_handoff",
             "engagement_id" => "eng_" <> String.duplicate("a", 32)
           }
         ]
       }}
    end

    def recheck(_source, _mailbox, _cap), do: :ok
  end

  setup do
    previous = Application.fetch_env(:arbor_security, :native_notice_source_authorizer)
    Application.put_env(:arbor_security, :native_notice_source_authorizer, SourceAuthority)
    {:ok, identity} = Identity.generate(name: "native-handoff")
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :native_notice_source_authorizer, value)

        :error ->
          Application.delete_env(:arbor_security, :native_notice_source_authorizer)
      end

      Security.delete_signing_key(identity.agent_id)
      Security.deregister_identity(identity.agent_id)
    end)

    %{identity: identity}
  end

  test "security regression: bootstrap waits for the actual worker's sensitive-ready handoff",
       c do
    observer = self()
    reference = make_ref()

    owner =
      spawn(fn ->
        {:ok, proof} =
          Security.build_signing_authority_acquisition_proof(
            c.identity.agent_id,
            c.identity.private_key,
            purpose: :session,
            owner: self()
          )

        {:ok, authority} = Security.open_signing_authority(proof)
        source = NativeNoticeWorker.open_source(authority)
        send(observer, {:source_ready, self(), is_reference(source)})

        receive do
          {:release, worker} ->
            send(observer, :release_entered)
            NativeNoticeWorker.release(worker, reference, source)
            send(observer, :release_completed)
        end

        receive do: (:stop -> :ok)
      end)

    worker =
      spawn(fn ->
        Process.put(:handoff_probe, :ordinary)
        receive do: (:start -> :ok)
        NativeNoticeWorker.await(reference, owner)
        send(observer, {:claimed_resource, Security.native_notice_action_resource(params())})
        receive do: (:stop -> apply(Security, :close_native_notice_worker, []))
      end)

    on_exit(fn ->
      for pid <- [worker, owner], Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    assert_receive {:source_ready, ^owner, true}, 2_000
    assert {:dictionary, [{:handoff_probe, :ordinary}]} = Process.info(worker, :dictionary)
    send(owner, {:release, worker})
    assert_receive :release_entered
    # A forged/stale correlation is not the fixed receiver's readiness.
    send(owner, {:native_notice_worker_ready, make_ref(), worker})
    refute_receive :release_completed, 50
    assert {:messages, []} = Process.info(worker, :messages)
    send(worker, :start)
    assert_receive :release_completed, 2_000
    assert_receive {:claimed_resource, {:ok, resource}}, 2_000
    assert resource =~ "arbor://comms/notice/publish/"
    assert {:dictionary, []} = Process.info(worker, :dictionary)
    send(worker, :stop)
    send(owner, :stop)
  end

  defp params do
    %{
      mailbox_id: "owner",
      notice_id: "notice_" <> String.duplicate("b", 32),
      kind: "notification",
      text: "private handoff notice"
    }
  end
end
