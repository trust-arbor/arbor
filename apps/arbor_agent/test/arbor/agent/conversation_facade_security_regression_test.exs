defmodule Arbor.Agent.ConversationFacadeSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :conversation_ingress
  alias Arbor.Agent.{ConversationFacade, MessageFacade}
  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Contracts.Pipeline.Response
  alias Arbor.Contracts.Security.{DeliveryReceipt, SignedRequest}

  @caller "human_conversation_test"
  @target "agent_conversation_test"
  @command %{id: "command-1", text: "Hello 東京 👋"}

  setup do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             authorized: true,
             active: true,
             canonical_owner: @caller,
             commands: %{},
             claims: %{},
             events: [],
             proofs: [],
             nonces: MapSet.new(),
             dispatched: 0,
             discarded: [],
             delivery: fn -> {:ok, Response.normalize(%{text: "Reply 東京"})} end
           }
         end}
      )

    message_collaborators = %{
      issue_receipt: fn caller, resource, action, opts ->
        assert caller == @caller
        assert resource == "arbor://chat/agent/" <> @target
        assert action == :chat

        Agent.get_and_update(state, fn current ->
          fresh =
            case opts do
              [session_token: "test-proof"] -> true
              [signed_request: %{nonce: nonce}] -> not MapSet.member?(current.nonces, nonce)
              _ -> false
            end

          nonces =
            case opts do
              [signed_request: %{nonce: nonce}] -> MapSet.put(current.nonces, nonce)
              _ -> current.nonces
            end

          next = %{current | proofs: [opts | current.proofs], nonces: nonces}

          result =
            if fresh and current.authorized and current.active,
              do: DeliveryReceipt.new(token: :crypto.strong_rand_bytes(32)),
              else: {:error, :unauthorized}

          {result, next}
        end)
      end,
      receipt_owner: fn _receipt, caller, target ->
        assert caller == @caller and target == @target

        case Agent.get(state, & &1.canonical_owner) do
          owner when is_binary(owner) -> {:ok, owner}
          _ -> {:error, :unauthorized}
        end
      end,
      recheck: fn caller, target, owner ->
        assert caller == @caller and target == @target

        if Agent.get(state, &(&1.authorized and &1.active and &1.canonical_owner == owner)),
          do: {:ok, :authorized},
          else: {:error, :unauthorized}
      end,
      discard_receipt: fn receipt ->
        Agent.update(state, &%{&1 | discarded: [receipt | &1.discarded]})
        :ok
      end,
      chat_response_authenticated: fn message, caller, receipt, opts ->
        assert caller == @caller
        assert message.sender_id == caller
        assert message.engagement_id == nil
        assert Keyword.keys(opts) == [:agent_id, :timeout]
        Agent.update(state, &%{&1 | dispatched: &1.dispatched + 1})
        send(parent, {:dispatched, self(), message, receipt})
        Agent.get(state, & &1.delivery).()
      end
    }

    collaborators = %{
      authenticate: fn caller, target, message, opts, continuation ->
        MessageFacade.with_authenticated_receipt(
          caller,
          target,
          message,
          opts,
          continuation,
          message_collaborators
        )
      end,
      resolve: fn target, caller ->
        {:ok,
         Engagement.new(
           id: "eng_00000000000000000000000000000001",
           agent_id: target,
           owner_tenant: caller,
           scope: :user,
           visibility: :private
         )}
      end,
      recheck: fn caller, target, canonical_owner ->
        assert caller == @caller and target == @target

        if Agent.get(
             state,
             &(&1.authorized and &1.active and &1.canonical_owner == canonical_owner)
           ),
           do: {:ok, :authorized},
           else: {:error, :unauthorized}
      end,
      admit: fn scope, command ->
        Agent.get_and_update(state, fn current ->
          key = {scope, command.id}

          case Map.get(current.commands, key) do
            nil ->
              admitted = Map.merge(scope, Map.merge(command, %{status: :admitted, outcome: nil}))
              {{:ok, admitted}, %{current | commands: Map.put(current.commands, key, admitted)}}

            %{text: text} = admitted when text == command.text ->
              {{:ok, admitted}, current}

            _ ->
              {{:error, :command_conflict}, current}
          end
        end)
      end,
      get: fn scope, id ->
        Agent.get(state, fn current ->
          case Map.fetch(current.commands, {scope, id}) do
            {:ok, command} -> {:ok, command}
            :error -> {:error, :not_found}
          end
        end)
      end,
      claim: fn scope, id ->
        Agent.get_and_update(state, fn current ->
          key = {scope, id}

          case Map.get(current.commands, key) do
            %{status: :admitted} = command ->
              token = make_ref()

              next = %{
                current
                | commands:
                    Map.put(current.commands, key, %{command | status: :dispatch_started}),
                  claims: Map.put(current.claims, key, token)
              }

              {{:ok, token}, next}

            _ ->
              {{:error, :already_claimed}, current}
          end
        end)
      end,
      settle: fn scope, id, token, outcome ->
        result =
          Agent.get_and_update(state, fn current ->
            key = {scope, id}
            command = Map.fetch!(current.commands, key)
            assert Map.fetch!(current.claims, key) == token

            if command.status == :dispatch_started do
              settled = %{command | status: outcome.status, outcome: outcome}
              {{:ok, settled}, %{current | commands: Map.put(current.commands, key, settled)}}
            else
              {{:ok, command}, current}
            end
          end)

        send(parent, {:settled, id, outcome})
        result
      end,
      events: fn _scope, cursor, page ->
        {:ok,
         %{events: [], cursor: cursor, head: Keyword.get(page, :through, cursor), has_more: false}}
      end,
      history: fn target, caller, page ->
        assert target == @target and caller == @caller
        {:ok, %{entries: [], cursor: Keyword.get(page, :after, 0), head: 0, has_more: false}}
      end,
      start_worker: &Task.Supervisor.start_child(supervisor, &1)
    }

    %{state: state, collaborators: collaborators, parent: parent}
  end

  test "security regression: exact retries reuse one scrubbed result without redispatch", c do
    assert {:ok, %{status: :admitted}} = request(c, :submit, @command)
    assert_receive {:settled, "command-1", %{status: :completed, text: "Reply 東京"}}
    assert {:ok, %{status: :completed}} = request(c, :submit, @command)
    assert {:error, :command_conflict} = request(c, :submit, %{@command | text: "changed"})
    assert {:ok, %{outcome: %{text: "Reply 東京"}}} = request(c, :command, @command.id)
    assert Agent.get(c.state, & &1.dispatched) == 1
    assert length(Agent.get(c.state, & &1.proofs)) == 4
  end

  test "security regression: fresh proof precedes existing command and event/history reads", c do
    assert {:ok, _} = request(c, :submit, @command)
    assert_receive {:settled, _, _}
    Agent.update(c.state, &%{&1 | authorized: false})

    for {operation, input} <- [
          {:submit, @command},
          {:command, @command.id},
          {:events, 0},
          {:history, nil}
        ] do
      assert {:error, :unauthorized} = request(c, operation, input)
    end

    assert Agent.get(c.state, & &1.dispatched) == 1
  end

  test "security regression: missing, wrong, mixed and replayed signed proofs fail closed", c do
    assert {:error, :unauthorized} = request(c, :history, nil, [])
    assert {:error, :unauthorized} = request(c, :history, nil, session_token: "wrong")

    assert {:error, :invalid_opts} =
             request(c, :history, nil,
               session_token: "test-proof",
               signed_request: proof(:history, nil, "n1")
             )

    assert {:ok, _} = request(c, :history, nil, signed_request: proof(:history, nil, "n1"))

    assert {:error, :unauthorized} =
             request(c, :history, nil, signed_request: proof(:history, nil, "n1"))

    assert {:ok, _} = request(c, :history, nil, signed_request: proof(:history, nil, "n2"))
    # One cryptographic issue call per request; release auth never reuses nonce.
    assert length(Agent.get(c.state, & &1.proofs)) == 4
  end

  test "security regression: signed proof binds operation target text command and page bounds",
       c do
    signed = proof(:submit, @command, "bound")

    for {operation, input, opts} <- [
          {:submit, %{@command | text: "altered"}, []},
          {:submit, %{@command | id: "altered"}, []},
          {:command, @command.id, []},
          {:history, nil, []},
          {:events, 0, [limit: 1]}
        ] do
      assert {:error, :unauthorized} =
               request(c, operation, input, [signed_request: signed] ++ opts)
    end

    assert Agent.get(c.state, & &1.proofs) == []
    assert {:ok, _} = request(c, :submit, @command, signed_request: signed)
    assert_receive {:settled, _, _}

    page_proof = proof(:history, nil, "page", after: 3, through: 10, limit: 2)

    assert {:error, :unauthorized} =
             request(c, :history, nil,
               signed_request: page_proof,
               after: 4,
               through: 10,
               limit: 2
             )

    assert {:error, :unauthorized} =
             request(c, :history, nil,
               signed_request: page_proof,
               after: 3,
               through: 11,
               limit: 2
             )

    assert {:error, :unauthorized} =
             request(c, :history, nil,
               signed_request: page_proof,
               after: 3,
               through: 10,
               limit: 3
             )

    assert {:error, :unauthorized} =
             ConversationFacade.run_with(
               :submit,
               @caller,
               "agent_other",
               @command,
               [signed_request: signed],
               c.collaborators
             )
  end

  test "security regression: engagement fence prevents reads and command admission after owner changes",
       c do
    assert {:ok, %{engagement_id: original}} = request(c, :events, 0)
    assert original == "eng_00000000000000000000000000000001"
    Agent.update(c.state, &%{&1 | canonical_owner: "human_new_owner"})

    collaborators = %{
      c.collaborators
      | resolve: fn target, owner ->
          assert owner == "human_new_owner"

          {:ok,
           Engagement.new(
             id: "eng_00000000000000000000000000000002",
             agent_id: target,
             owner_tenant: owner,
             scope: :user,
             visibility: :private
           )}
        end,
        admit: fn _, _ -> flunk("scope changed before command admission") end,
        get: fn _, _ -> flunk("scope changed before command read") end,
        events: fn _, _, _ -> flunk("scope changed before event read") end,
        history: fn _, _, _ -> flunk("scope changed before transcript read") end
    }

    for {operation, input} <- [submit: @command, command: @command.id, events: 0, history: nil] do
      assert {:error, :conversation_scope_changed} =
               request(%{c | collaborators: collaborators}, operation, input,
                 session_token: "test-proof",
                 expected_engagement_id: original
               )
    end

    assert Agent.get(c.state, & &1.commands) == %{}
    assert Agent.get(c.state, & &1.dispatched) == 0
  end

  test "security regression: engagement fence is bounded and signed before proof consumption",
       c do
    original = "eng_00000000000000000000000000000001"
    changed = "eng_00000000000000000000000000000002"
    signed = proof(:events, 0, "fenced", expected_engagement_id: original)

    assert {:error, :unauthorized} =
             request(c, :events, 0, signed_request: signed, expected_engagement_id: changed)

    assert {:error, :unauthorized} = request(c, :events, 0, signed_request: signed)

    for bad <- ["eng_wrong", String.duplicate("x", 300), %{}, 1] do
      assert {:error, :invalid_opts} =
               request(c, :history, nil, session_token: "test-proof", expected_engagement_id: bad)
    end

    assert Agent.get(c.state, & &1.proofs) == []

    assert {:ok, %{engagement_id: ^original}} =
             request(c, :events, 0, signed_request: signed, expected_engagement_id: original)
  end

  test "security regression: linked canonical owner scopes history but never replaces proof subject",
       c do
    Agent.update(c.state, &%{&1 | canonical_owner: "human_primary"})
    parent = self()

    collaborators = %{
      c.collaborators
      | history: fn target, owner, _page ->
          send(parent, {:history_owner, target, owner})
          {:ok, %{entries: [], cursor: 0, head: 0, has_more: false}}
        end
    }

    assert {:ok, _} = request(%{c | collaborators: collaborators}, :history, nil)
    assert_receive {:history_owner, @target, "human_primary"}
    assert length(Agent.get(c.state, & &1.proofs)) == 1
  end

  test "security regression: unlink or resolver outage after read denies publication without rescope",
       c do
    Agent.update(c.state, &%{&1 | canonical_owner: "human_primary"})

    for changed <- [@caller, nil] do
      Agent.update(c.state, &%{&1 | canonical_owner: "human_primary"})

      collaborators = %{
        c.collaborators
        | history: fn _target, "human_primary", _page ->
            Agent.update(c.state, &%{&1 | canonical_owner: changed})
            {:ok, %{entries: [%{content: "private"}]}}
          end
      }

      assert {:error, :unauthorized} = request(%{c | collaborators: collaborators}, :history, nil)
    end
  end

  test "security regression: public entry options cannot supply route or authorization collaborators",
       c do
    for extra <- [
          engagement_id: "other",
          collaborators: %{},
          identity_verified: true,
          verify_identity: false,
          principal_id: "human_other",
          after: 0
        ] do
      assert {:error, :invalid_opts} =
               request(c, :submit, @command, [{:session_token, "test-proof"}, extra])
    end

    assert {:error, :invalid_opts} =
             request(c, :history, nil, session_token: "test-proof", limit: 101)

    assert {:error, :invalid_opts} =
             request(c, :events, 0, session_token: "test-proof", limit: 1, limit: 2)

    assert {:error, :invalid_command} =
             request(c, :submit, Map.put(@command, :engagement_id, "route"))

    assert {:error, :invalid_command} = request(c, :submit, %{@command | id: "../escape"})
    assert Agent.get(c.state, & &1.proofs) == []
  end

  test "security regression: wrong owner or public engagement cannot route a private conversation",
       c do
    for overrides <- [
          [owner_tenant: "human_other"],
          [visibility: :public],
          [agent_id: "agent_other"]
        ] do
      collaborators = %{
        c.collaborators
        | resolve: fn target, caller ->
            {:ok,
             Engagement.new(
               Keyword.merge(
                 [id: "eng_wrong", agent_id: target, owner_tenant: caller, scope: :user],
                 overrides
               )
             )}
          end
      }

      assert {:error, :unauthorized} = request(%{c | collaborators: collaborators}, :history, nil)
    end
  end

  test "security regression: read release denies capability revocation and identity suspension",
       c do
    for field <- [:authorized, :active] do
      Agent.update(c.state, &Map.put(&1, field, true))

      collaborators = %{
        c.collaborators
        | events: fn _scope, _cursor, _page ->
            Agent.update(c.state, &Map.put(&1, field, false))
            {:ok, %{events: [%{text: "private result"}], cursor: 1, head: 1, has_more: false}}
          end
      }

      assert {:error, :unauthorized} = request(%{c | collaborators: collaborators}, :events, 0)
      Agent.update(c.state, &Map.put(&1, field, true))
    end
  end

  test "security regression: caller death after admission cannot kill supervised delivery", c do
    parent = self()

    Agent.update(
      c.state,
      &%{
        &1
        | delivery: fn ->
            send(parent, {:delivery_blocked, self()})

            receive do
              :finish -> {:ok, Response.normalize(%{text: "survived"})}
            end
          end
      }
    )

    caller =
      spawn(fn ->
        result = request(c, :submit, @command)
        send(parent, {:admitted, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:admitted, {:ok, %{status: :admitted}}}
    assert_receive {:delivery_blocked, worker}
    Process.exit(caller, :kill)
    assert Process.alive?(worker)
    send(worker, :finish)
    assert_receive {:settled, _, %{status: :completed, text: "survived"}}
    assert {:ok, %{status: :completed}} = request(c, :command, @command.id)
  end

  test "security regression: revocation during delivery cannot publish a completed journal reply",
       c do
    parent = self()

    Agent.update(
      c.state,
      &%{
        &1
        | delivery: fn ->
            send(parent, {:delivery_blocked, self()})

            receive do
              :finish -> {:ok, Response.normalize(%{text: "revoked private reply"})}
            end
          end
      }
    )

    assert {:ok, %{status: :admitted}} = request(c, :submit, @command)
    assert_receive {:delivery_blocked, worker}
    Agent.update(c.state, &%{&1 | authorized: false})
    send(worker, :finish)
    assert_receive {:settled, _, %{status: :uncertain, reason: :delivery_unknown}}
    refute inspect(Agent.get(c.state, & &1.commands)) =~ "revoked private reply"
  end

  test "security regression: dispatch errors and secret-bearing replies become immutable uncertainty",
       c do
    for {id, delivery} <- [
          {"timeout", fn -> {:error, :delivery_ambiguous} end},
          {"error", fn -> {:error, :turn_commit_failed} end},
          {"secret", fn -> {:ok, Response.normalize(%{text: "contains test-proof"})} end},
          {"oversized",
           fn -> {:ok, Response.normalize(%{text: String.duplicate("x", 131_073)})} end}
        ] do
      Agent.update(c.state, &%{&1 | delivery: delivery})
      command = %{@command | id: id}
      assert {:ok, _} = request(c, :submit, command)
      assert_receive {:settled, ^id, %{status: :uncertain, reason: :delivery_unknown}}
      assert {:ok, %{status: :uncertain}} = request(c, :submit, command)
    end

    assert Agent.get(c.state, & &1.dispatched) == 4
  end

  test "security regression: a killed claimed worker stays unknown and retries never redispatch",
       c do
    parent = self()

    Agent.update(
      c.state,
      &%{
        &1
        | delivery: fn ->
            send(parent, {:delivery_blocked, self()})

            receive do
              :never -> :ok
            end
          end
      }
    )

    assert {:ok, _} = request(c, :submit, @command)
    assert_receive {:delivery_blocked, worker}
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert {:ok, %{status: :dispatch_started, outcome: nil}} = request(c, :submit, @command)
    assert Agent.get(c.state, & &1.dispatched) == 1
  end

  test "security regression: revocation after claim prevents Session dispatch", c do
    claim = c.collaborators.claim

    collaborators = %{
      c.collaborators
      | claim: fn scope, id ->
          result = claim.(scope, id)
          Agent.update(c.state, &%{&1 | authorized: false})
          result
        end
    }

    # Publication may win or lose its own revocation race; neither allows dispatch.
    assert request(%{c | collaborators: collaborators}, :submit, @command) in [
             {:error, :unauthorized},
             {:ok,
              Map.merge(@command, %{
                status: :admitted,
                outcome: nil,
                principal_id: @caller,
                agent_id: @target,
                engagement_id: "eng_00000000000000000000000000000001"
              })}
           ]

    assert_receive {:settled, _, %{status: :uncertain}}
    assert Agent.get(c.state, & &1.dispatched) == 0
  end

  test "history and command event cursors stay separate and reads discard unused receipts", c do
    assert {:ok, %{cursor: 7}} =
             request(c, :history, nil,
               session_token: "test-proof",
               after: 7,
               through: 10,
               limit: 2
             )

    assert {:ok, %{cursor: 2, head: 3}} =
             request(c, :events, 2, session_token: "test-proof", through: 3, limit: 1)

    assert Agent.get(c.state, & &1.dispatched) == 0
    assert length(Agent.get(c.state, & &1.discarded)) == 2
  end

  test "security regression: backend error details and malformed successes never cross the public boundary",
       c do
    for reply <- [
          {:error, {:database_error, "private DSN and query"}},
          {:ok, "wrong shape"},
          :oops
        ] do
      collaborators = %{c.collaborators | history: fn _, _, _ -> reply end}

      assert {:error, :conversation_unavailable} =
               request(%{c | collaborators: collaborators}, :history, nil)
    end
  end

  defp proof(operation, input, nonce, opts \\ []) do
    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(operation, @caller, @target, input, opts)

    {:ok, request} =
      SignedRequest.new(
        agent_id: @caller,
        payload: payload,
        signature: :binary.copy(<<0>>, 64),
        timestamp: DateTime.utc_now(),
        nonce: binary_part(:crypto.hash(:sha256, nonce), 0, 16)
      )

    request
  end

  defp request(c, operation, input, opts \\ [session_token: "test-proof"]) do
    ConversationFacade.run_with(operation, @caller, @target, input, opts, c.collaborators)
  end
end
