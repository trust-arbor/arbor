defmodule Arbor.Security.NativeNoticeBrokerSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  # Trusted compiled DI fixture for the lower owner-bound protocol, not proof of
  # Agent topology. Actual Session/Heartbeat acquisition is qualified above it.
  defmodule SourceAuthority do
    @behaviour Arbor.Security.Contracts.NativeNoticeSourceAuthorizer
    def acquire(principal, owner) do
      {:ok,
       %{
         principal_id: principal,
         owner_pid: owner,
         branch_pid: owner,
         role: :session,
         mailboxes: [mailbox()]
       }}
    end

    def recheck(_source, _mailbox, _cap), do: :ok

    def mailbox,
      do: %{
        "mailbox_id" => "owner",
        "recipient_subject_id" => "human_notice_test",
        "owner_id" => "human_notice_test",
        "engagement_id" => "eng_" <> String.duplicate("a", 32)
      }
  end

  setup do
    previous = Application.fetch_env(:arbor_security, :native_notice_source_authorizer)
    Application.put_env(:arbor_security, :native_notice_source_authorizer, SourceAuthority)
    {:ok, identity} = Identity.generate(name: "native-notice-test")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))
    :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :native_notice_source_authorizer, value)

        :error ->
          Application.delete_env(:arbor_security, :native_notice_source_authorizer)
      end

      Security.delete_signing_key_fixture(identity.agent_id)
      Security.deregister_identity_fixture(identity.agent_id)
    end)

    %{identity: identity, authority: authority}
  end

  test "security regression: direct maps and process labels cannot obtain native SQL admission",
       c do
    params = params()
    Process.put({Arbor.Actions, :conversation_source}, %{agent_id: c.identity.agent_id})

    scope = %{
      owner_id: "human_notice_test",
      target_agent_id: c.identity.agent_id,
      engagement_id: SourceAuthority.mailbox()["engagement_id"]
    }

    assert {:error, :native_notice_source_required} =
             Security.native_notice_action_resource(params)

    assert {:error, :native_notice_source_required} =
             Security.consume_native_notice_commit(scope, %{})

    assert {:error, :native_notice_source_required} =
             Security.reconcile_native_notice_commit(scope, %{})

    Process.delete({Arbor.Actions, :conversation_source})
  end

  test "security regression: absent native role adapter denies key-only acquisition", c do
    Application.put_env(:arbor_security, :native_notice_source_authorizer, nil)

    assert {:error, :native_notice_source_required} =
             Security.open_native_notice_source(c.authority)
  end

  test "security regression: transferable signing authority is not transferable source authority",
       c do
    task = Task.async(fn -> Security.open_native_notice_source(c.authority) end)
    assert {:error, :native_notice_source_required} = Task.await(task)
  end

  test "security regression: native source signing is domain specific", c do
    assert {:ok, source_facts} = SourceAuthority.acquire(c.identity.agent_id, self())
    payload = Arbor.Security.NativeConversationNotices.acquisition_payload(source_facts)

    assert {:error, :invalid_resource_binding} =
             Arbor.Security.SigningAuthorityBroker.sign(c.authority, payload)

    assert {:ok, source} = Security.open_native_notice_source(c.authority)
    assert is_reference(source)
  end

  test "one-use bootstrap is bound to the exact held worker", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = worker()
    {:ok, bootstrap} = Security.delegate_native_notice_worker(source, worker)

    assert {:error, :native_notice_source_required} =
             Security.claim_native_notice_worker(bootstrap)

    assert :ok = request(worker, {:claim, bootstrap})
    assert {:error, :native_notice_source_required} = request(worker, {:claim, bootstrap})
    assert {:ok, _} = request(worker, {:resource, params()})
  end

  test "profile mutation retires source and fences reacquisition through release", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    assert {:ok, _} = request(worker, {:resource, params()})
    assert {:ok, ticket} = Security.begin_native_notice_profile_mutation(c.identity.agent_id)
    assert {:error, :native_notice_source_required} = request(worker, {:resource, params()})

    assert {:error, :native_notice_source_required} =
             Security.open_native_notice_source(c.authority)

    assert :ok = Security.finish_native_notice_profile_mutation(ticket)

    assert {:error, :native_notice_source_required} =
             Security.delegate_native_notice_worker(source, worker())

    assert {:ok, successor} = Security.open_native_notice_source(c.authority)
    assert successor != source
  end

  test "finite max-use notice grant is refused before allowance consumption", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    {:ok, resource} = request(worker, {:resource, params()})

    {:ok, cap} =
      Security.grant_fixture(principal: c.identity.agent_id, resource: resource, max_uses: 1)

    assert {:error, :unsupported_notice_capability} = request(worker, {:prepare, params()})
    assert {:ok, :authorized} = authorize(c.identity, resource)
    assert {:error, _} = authorize(c.identity, resource)
    assert is_binary(cap.id)
  end

  test "exact prepared capability revocation cannot fall back to covering replacement", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    {:ok, resource} = request(worker, {:resource, params()})
    {:ok, cap} = Security.grant_fixture(principal: c.identity.agent_id, resource: resource)
    {:ok, %{prepared: token}} = request(worker, {:prepare, params()})
    assert :ok = Security.revoke_fixture(cap.id)

    assert {:ok, _replacement} =
             Security.grant_fixture(principal: c.identity.agent_id, resource: resource)

    assert {:error, :unauthorized} = request(worker, {:activate, token})
  end

  test "rate allowance consumes once; identical readonly reconciliation consumes none", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    {:ok, resource} = request(worker, {:resource, params()})

    {:ok, _} =
      Security.grant_fixture(
        principal: c.identity.agent_id,
        resource: resource,
        constraints: %{rate_limit: 1}
      )

    {:ok, %{prepared: token}} = request(worker, {:prepare, params()})
    assert :ok = request(worker, {:activate, token})
    {:ok, %{scope: scope, value: value}} = request(worker, {:peek, params()})
    assert :ok = request(worker, {:consume, scope, value})
    assert {:error, :native_notice_source_required} = request(worker, {:consume, scope, value})
    assert :ok = request(worker, {:finish, params(), :stored})
    {:ok, %{prepared: replay}} = request(worker, {:prepare, params()})
    assert :ok = request(worker, {:activate, replay})
    assert :ok = request(worker, {:reconcile, scope, value})
    assert :ok = request(worker, {:finish, params(), :stored})
    assert {:error, _} = authorize(c.identity, resource)
  end

  test "security regression: dead queued worker cannot consume before its DOWN arrives", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    {:ok, resource} = request(worker, {:resource, params()})

    {:ok, _} =
      Security.grant_fixture(
        principal: c.identity.agent_id,
        resource: resource,
        constraints: %{rate_limit: 1}
      )

    {:ok, %{prepared: token}} = request(worker, {:prepare, params()})
    assert :ok = request(worker, {:activate, token})
    {:ok, %{scope: scope, value: value}} = request(worker, {:peek, params()})
    broker = Process.whereis(Arbor.Security.NativeNoticeBroker)
    :ok = :sys.suspend(broker)

    try do
      send(worker, {self(), make_ref(), {:consume, scope, value}})
      wait_for_native_call(worker)
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    after
      :ok = :sys.resume(broker)
    end

    assert {:ok, :authorized} = authorize(c.identity, resource)
  end

  test "security regression: forged GenServer from cannot borrow a live native worker", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    assert {:ok, resource} = request(worker, {:resource, params()})
    {:ok, _} = Security.grant_fixture(principal: c.identity.agent_id, resource: resource)
    {:ok, %{prepared: token}} = request(worker, {:prepare, params()})
    assert :ok = request(worker, {:activate, token})
    {:ok, %{scope: scope, value: value}} = request(worker, {:peek, params()})

    for message <- [
          {:resource, params()},
          {:consume_value, scope, value},
          {:worker, nil, {:consume_value, scope, value}},
          {:worker, make_ref(), {:consume_value, scope, value}},
          {:worker, make_ref(), :discard}
        ] do
      assert {:error, :native_notice_source_required} = forged_call(worker, message)
    end

    # None of the impostor messages consumed or discarded actual admission.
    assert :ok = request(worker, {:consume, scope, value})
    assert :ok = request(worker, {:finish, params(), :stored})
  end

  test "security regression: copied or invented private locator is not worker authority", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    locator = request(worker, :custody_locator)
    assert :ets.info(locator, :owner) == worker
    assert_raise ArgumentError, fn -> :ets.lookup(locator, :custody) end
    key = {Arbor.Security.NativeConversationNotices, :worker_custody}
    old = Process.get(key)

    try do
      for fake <- [locator, make_ref()] do
        Process.put(key, fake)

        assert {:error, :native_notice_source_required} =
                 Security.native_notice_action_resource(params())
      end
    after
      if is_nil(old), do: Process.delete(key), else: Process.put(key, old)
    end

    assert {:ok, _} = request(worker, {:resource, params()})
    assert :ok = request(worker, :close)
    assert :ets.info(locator) == :undefined
    assert {:error, :native_notice_source_required} = request(worker, {:resource, params()})
  end

  test "security regression: ordinary state and status expose no source custody", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = claimed_worker(source)
    assert {:ok, _} = request(worker, {:resource, params()})
    broker = Process.whereis(Arbor.Security.NativeNoticeBroker)
    assert %{private_state: locator} = :sys.get_state(broker)
    assert Map.keys(:sys.get_state(broker)) == [:private_state]
    assert_raise ArgumentError, fn -> :ets.lookup(locator, :state) end
    status = inspect(:sys.get_status(broker), limit: :infinity)
    refute status =~ "Private native notice"
    refute status =~ "human_notice_test"
    refute status =~ inspect(source)
    # Ordinary Process.info cannot reveal a sensitive worker's private locator.
    assert {:dictionary, []} = Process.info(worker, :dictionary)
  end

  test "security regression: transferred replacement custody cannot mint native authority", c do
    broker = Process.whereis(Arbor.Security.NativeNoticeBroker)
    original_state = :sys.get_state(broker)
    fake_authenticated_calls = Arbor.Common.new_authenticated_call_custody()
    hostile = :ets.new(__MODULE__, [:set, :private])

    true =
      :ets.insert(
        hostile,
        {:native_notice_broker_v1,
         %{
           acquisitions: %{},
           authenticated_calls: fake_authenticated_calls,
           generations: %{},
           monitors: %{},
           mutations: %{},
           reservations: %{},
           sources: %{},
           workers: %{}
         }}
      )

    true = :ets.give_away(hostile, broker, :hostile_native_notice_state)
    assert :ets.info(hostile, :owner) == broker
    :sys.replace_state(broker, fn _state -> %{private_state: hostile} end)

    assert {:error, :notice_unavailable} =
             Security.begin_native_notice_profile_mutation(c.identity.agent_id)

    next_broker = wait_for_replacement(Arbor.Security.NativeNoticeBroker, broker)
    assert next_broker != broker
    refute Process.alive?(broker)

    assert {:ok, source} = Security.open_native_notice_source(c.authority)
    assert is_reference(source)
    refute original_state == :sys.get_state(next_broker)
  end

  test "security regression: source-owner private replies are sensitive before acquisition", c do
    parent = self()

    owner =
      spawn(fn ->
        Process.put(:handoff_privacy_probe, :ordinary)

        {:ok, proof} =
          Security.build_signing_authority_acquisition_proof(
            c.identity.agent_id,
            c.identity.private_key,
            purpose: :session,
            owner: self()
          )

        {:ok, authority} = Security.open_signing_authority(proof)
        send(parent, {:source_owner_ready, self()})

        receive do
          :open -> send(parent, {:source_opened, Security.open_native_notice_source(authority)})
        end

        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:source_owner_ready, ^owner}
    broker = Process.whereis(Arbor.Security.NativeNoticeBroker)
    :ok = :sys.suspend(broker)

    try do
      send(owner, :open)
      wait_for_native_call(owner)
      assert {:dictionary, []} = Process.info(owner, :dictionary)
      true = :erlang.suspend_process(owner)
      :ok = :sys.resume(broker)
      wait_for_queued_reply(owner)
      assert {:messages, []} = Process.info(owner, :messages)
      assert {:dictionary, []} = Process.info(owner, :dictionary)
    after
      resume_if_suspended(owner)
      resume_broker(broker)
    end

    assert_receive {:source_opened, {:ok, source}}, 2_000
    assert is_reference(source)
    send(owner, :stop)
  end

  test "security regression: pending claim protects the queued custody reply", c do
    {:ok, source} = Security.open_native_notice_source(c.authority)
    worker = worker()
    {:ok, bootstrap} = Security.delegate_native_notice_worker(source, worker)
    broker = Process.whereis(Arbor.Security.NativeNoticeBroker)
    :ok = :sys.suspend(broker)
    ref = make_ref()

    try do
      send(worker, {self(), ref, {:claim, bootstrap}})
      wait_for_native_call(worker)
      assert {:dictionary, []} = Process.info(worker, :dictionary)
      true = :erlang.suspend_process(worker)
      :ok = :sys.resume(broker)
      wait_for_queued_reply(worker)
      assert {:messages, []} = Process.info(worker, :messages)
      assert {:dictionary, []} = Process.info(worker, :dictionary)
    after
      resume_if_suspended(worker)
      resume_broker(broker)
    end

    assert_receive {^ref, :ok}, 2_000
    assert {:ok, _} = request(worker, {:resource, params()})
  end

  defp wait_for_queued_reply(pid, attempts \\ 400)
  defp wait_for_queued_reply(_pid, 0), do: flunk("private reply was not queued")

  defp wait_for_queued_reply(pid, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} when count > 0 ->
        :ok

      _ ->
        Process.sleep(5)
        wait_for_queued_reply(pid, attempts - 1)
    end
  end

  defp resume_if_suspended(pid) do
    if Process.info(pid, :status) == {:status, :suspended}, do: :erlang.resume_process(pid)
  end

  defp resume_broker(broker) do
    :sys.resume(broker)
  catch
    :exit, _ -> :ok
  end

  defp forged_call(victim, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(Arbor.Security.NativeNoticeBroker, {:"$gen_call", {victim, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged native message did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end

  defp params,
    do: %{
      mailbox_id: "owner",
      notice_id: "notice_" <> String.duplicate("b", 32),
      kind: "notification",
      text: "Private native notice"
    }

  defp authorize(identity, resource) do
    {:ok, proof} =
      Arbor.Contracts.Security.SignedRequest.sign(
        resource,
        identity.agent_id,
        identity.private_key
      )

    Security.authorize(identity.agent_id, resource, :execute,
      signed_request: proof,
      expected_resource: resource
    )
  end

  defp claimed_worker(source) do
    worker = worker()
    {:ok, bootstrap} = Security.delegate_native_notice_worker(source, worker)
    :ok = request(worker, {:claim, bootstrap})
    worker
  end

  defp worker do
    pid =
      spawn(fn ->
        Process.put(:handoff_privacy_probe, :ordinary)
        loop()
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp loop do
    receive do
      {parent, ref, operation} ->
        result =
          case operation do
            {:claim, token} ->
              Security.claim_native_notice_worker(token)

            {:resource, params} ->
              Security.native_notice_action_resource(params)

            {:prepare, params} ->
              Security.prepare_native_notice_publication(params, nil)

            {:activate, token} ->
              Security.activate_native_notice_publication(token)

            {:peek, params} ->
              Security.native_notice_publication_value(params)

            {:consume, scope, value} ->
              Security.consume_native_notice_commit(scope, value)

            {:reconcile, scope, value} ->
              Security.reconcile_native_notice_commit(scope, value)

            {:finish, params, outcome} ->
              Security.finish_native_notice_publication(params, outcome)

            :custody_locator ->
              Process.get({Arbor.Security.NativeConversationNotices, :worker_custody})

            :close ->
              apply(Security, :close_native_notice_worker, [])
          end

        send(parent, {ref, result})
        loop()
    end
  end

  defp request(worker, operation) do
    ref = make_ref()
    send(worker, {self(), ref, operation})

    receive do
      {^ref, result} -> result
    after
      2_000 -> flunk("native worker call timed out")
    end
  end

  defp wait_for_native_call(worker, attempts \\ 400)
  defp wait_for_native_call(_worker, 0), do: flunk("worker did not enter native commit call")

  defp wait_for_native_call(worker, attempts) do
    case Process.info(worker, :current_function) do
      {:current_function, {Arbor.Common.AuthenticatedCall, function, _arity}}
      when function in [:await_challenge, :await_reply] ->
        :ok

      _ ->
        Process.sleep(5)
        wait_for_native_call(worker, attempts - 1)
    end
  end

  defp wait_for_replacement(name, old, attempts \\ 200)
  defp wait_for_replacement(_name, _old, 0), do: flunk("supervised broker did not restart")

  defp wait_for_replacement(name, old, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        Process.sleep(5)
        wait_for_replacement(name, old, attempts - 1)
    end
  end
end
