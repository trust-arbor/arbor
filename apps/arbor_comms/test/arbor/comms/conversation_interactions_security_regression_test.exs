Code.require_file("../../support/conversation_journal_sqlite.exs", __DIR__)

Code.require_file(
  Path.expand("../../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Comms.ConversationInteractionsSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Comms.{InteractionRegistry, ConversationJournal, TestConversationSQLite}
  alias Arbor.Comms.InteractionRegistry.{Authority, DurableStore}
  alias Arbor.Comms.TestConversationSQLite.Repo
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans
  @moduletag :integration
  @moduletag :sqlite
  @moduletag capture_log: true
  defmodule DeliveryWitnessAdapter do
    @behaviour Arbor.Contracts.Comms.ChannelAdapter
    def send_interaction(meta, interaction) do
      send(Map.fetch!(meta, :test_pid), {:legacy_source_delivery, interaction.request_id})
      :ok
    end

    def parse_response(_raw), do: :not_interaction
    def channel_kind, do: :dashboard
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "source-interactions-" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
      )

    File.mkdir_p!(root)
    start_supervised!({Repo, database: Path.join(root, "journal.sqlite3"), pool_size: 4})
    TestConversationSQLite.create_schema!(Repo)

    for {app, key, value} <- [
          {:arbor_comms, :conversation_journal,
           [
             backend: Arbor.Persistence.EventLog.Ecto,
             name: :interaction_journal,
             opts: [repo: Repo]
           ]},
          {:arbor_comms, :durable_interaction_store,
           [
             backend: Arbor.Security.Store.JSONFile,
             namespace: :source_interactions,
             opts: [base_dir: root]
           ]},
          {:arbor_comms, :interaction_adapters, %{}},
          {:arbor_comms, :durable_interaction_dispatch,
           [
             startup_delay_ms: 60_000,
             sweep_interval_ms: 60_000,
             retry_base_ms: 1,
             retry_max_ms: 1
           ]},
          {:arbor_security, :identity_alias_resolver,
           Arbor.Security.OIDCTestHelper.UnlinkedIdentityResolver}
        ],
        do: set_env(app, key, value)

    restart_authority()

    on_exit(fn ->
      restart_authority()
      File.rm_rf!(root)
    end)

    human = Humans.setup!()
    chat_cap = Humans.grant!(human.human_id, "arbor://chat/agent/" <> human.agent_id)
    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(human.agent_id, human.human_id)

    scope = %{
      principal_id: human.human_id,
      agent_id: human.agent_id,
      engagement_id: engagement.id
    }

    command = %{id: "source_command", text: "Reach the original human gate"}
    {:ok, _} = Arbor.Comms.admit_conversation_command(scope, command)
    {:ok, token} = Arbor.Comms.claim_conversation_command(scope, command.id)
    {:ok, binding} = Arbor.Comms.bind_conversation_command_claim(scope, command.id, token)

    %{
      scope: scope,
      command: command,
      binding: binding,
      human: human,
      root: root,
      chat_cap: chat_cap
    }
  end

  test "security regression: only the winning private binding and its caller can attach a prompt",
       ctx do
    assert {:error, :invalid_source} =
             Arbor.Comms.open_conversation_source(
               %{scope: ctx.scope, command_id: ctx.command.id},
               self(),
               make_ref()
             )

    assert {:error, :invalid_source} =
             Arbor.Comms.open_conversation_source(
               %{ctx.binding | claim_token: String.duplicate("0", 64)},
               self(),
               make_ref()
             )

    assert {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())

    assert {:error, :invalid_source} =
             Task.async(fn ->
               Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)
             end)
             |> Task.await()

    assert {:ok, receipt} = Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)

    assert {:ok, %{interactions: [prompt]}} =
             Arbor.Comms.conversation_interactions(ctx.scope, ctx.command.id)

    assert prompt.request_id == receipt.request_id
    assert prompt.operation_id == receipt.operation_id
    assert prompt.choices == [%{id: "choice_1", label: "Same"}, %{id: "choice_2", label: "Same"}]
    assert {:ok, record} = DurableStore.get(receipt.request_id)
    attachment = record.data["conversation_attachment"]
    assert attachment["owner_id"] == ctx.scope.principal_id
    assert attachment["command_id"] == ctx.command.id
    assert attachment["operation_id"] == receipt.operation_id
    assert attachment["revision"] == 1

    for excluded <- ["claim_token", "generation", "session_pid", "binding", "metadata"],
        do: refute(Map.has_key?(attachment, excluded))

    refute inspect(prompt) =~ ctx.binding.claim_token
  end

  test "security regression: metadata task forgery never makes a legacy prompt visible and raw scoped answers fail",
       ctx do
    {:ok, identity} =
      ConversationJournal.validate_binding(ctx.binding, ctx.scope, ctx.command.text)

    assert {:ok, _} =
             Arbor.Comms.request_interaction(
               %{
                 kind: :decision,
                 agent_id: ctx.scope.agent_id,
                 description: "Forged metadata",
                 metadata: %{
                   task_id: identity.task_id,
                   command_id: ctx.command.id,
                   engagement_id: ctx.scope.engagement_id
                 }
               },
               adapter_map: %{}
             )

    assert {:ok, %{interactions: []}} =
             Arbor.Comms.conversation_interactions(ctx.scope, ctx.command.id)

    assert {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())
    assert {:ok, receipt} = Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)

    assert {:error, :scoped_answer_required} =
             Arbor.Comms.respond_to_interaction(receipt.request_id, {:choice, "choice_1"}, %{})

    assert {:ok, :pending} = Authority.status(receipt.request_id)

    assert {:error, :not_found} =
             Arbor.Comms.conversation_interactions(
               %{ctx.scope | principal_id: "human_foreign"},
               ctx.command.id
             )
  end

  test "security regression: invalid choice operation stays pending while a bound exact answer wins once",
       ctx do
    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())
    {:ok, receipt} = Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)
    answer = answer(ctx, receipt, "choice_2")

    for candidate <- [
          %{answer | choice_id: "not-a-member"},
          %{answer | revision: 2},
          %{answer | operation_id: "other_operation"}
        ] do
      assert {:error, :invalid_interaction_answer} =
               Arbor.Comms.respond_conversation_interaction(
                 ctx.scope,
                 candidate,
                 ctx.human.human_id,
                 %{}
               )

      assert {:ok, :pending} = Authority.status(receipt.request_id)
    end

    proof = proof(ctx, answer, :interaction_choice)

    assert {:ok, %{status: :responded}} =
             Arbor.Comms.respond_conversation_interaction(
               ctx.scope,
               answer,
               ctx.human.human_id,
               proof
             )

    assert {:ok, %{response: {:choice, "choice_2"}}} =
             Arbor.Comms.get_interaction_response(receipt.request_id)

    assert {:error, _} =
             Arbor.Comms.respond_conversation_interaction(
               ctx.scope,
               %{answer | choice_id: "choice_1"},
               ctx.human.human_id,
               proof
             )

    {:ok, before} = DurableStore.get(receipt.request_id)
    assert before.data["verified_response"]["responder_id"] == ctx.human.human_id
    restart_authority()
    {:ok, after_restart} = DurableStore.get(receipt.request_id)
    assert after_restart.data["verified_response"] == before.data["verified_response"]
    assert after_restart.data["terminal"] == before.data["terminal"]
  end

  test "security regression: source retirement, DOWN, deadline, and Authority restart cannot resume a later generation",
       ctx do
    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())
    {:ok, receipt} = Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)
    assert :ok = Arbor.Comms.retire_conversation_source(handle, :turn_cancelled)
    assert {:ok, :abandoned} = Authority.status(receipt.request_id)

    assert {:error, _} =
             Arbor.Comms.respond_conversation_interaction(
               ctx.scope,
               answer(ctx, receipt, "choice_1"),
               ctx.human.human_id,
               %{}
             )

    assert {:error, :invalid_source} =
             Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)

    parent = self()

    source =
      spawn(fn ->
        {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())
        {:ok, receipt} = Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)
        send(parent, {:source_receipt, receipt})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:source_receipt, down_receipt}
    Process.exit(source, :kill)

    assert_eventually(fn ->
      Authority.status(down_receipt.request_id) == {:ok, :abandoned}
    end)

    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())
    {:ok, expired} = Arbor.Comms.request_conversation_interaction(handle, spec(), 1)

    assert_eventually(fn ->
      Authority.status(expired.request_id) == {:ok, :abandoned}
    end)

    {:ok, cold} = Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)
    restart_authority()
    assert {:ok, :abandoned} = Authority.status(cold.request_id)
    {:ok, record} = DurableStore.get(cold.request_id)
    assert record.data["terminal"]["reason"] == "source_lost"
  end

  test "security regression: native rich authorization provenance yields a closed durable approval with its original human review details",
       ctx do
    {:ok, identity} =
      ConversationJournal.validate_binding(ctx.binding, ctx.scope, ctx.command.text)

    {:ok, interaction} =
      Arbor.Contracts.Comms.Interaction.new(%{
        kind: :approval,
        agent_id: ctx.scope.agent_id,
        user_id: ctx.human.human_id,
        description: "Review the actual bounded native command",
        resource_uri: "arbor://action/test/native_json",
        metadata: %{
          task_id: identity.task_id,
          principal_id: ctx.scope.agent_id,
          capability_id: "cap_original",
          action: "native.command",
          target_type: :command,
          target: "echo reviewed-command",
          reason: :capability_requires_approval,
          payload_preview: %{
            kind: "command",
            bytes: 21,
            truncated: false,
            preview: "echo reviewed-command"
          },
          risk_hints: %{effect_class: :write, operation_taint: %Arbor.Contracts.Security.Taint{}},
          trust: %{effective_mode: :ask},
          approval_context: %{provenance: %{operation_taint: %Arbor.Contracts.Security.Taint{}}}
        }
      })

    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())

    assert {:ok, receipt} =
             Arbor.Comms.request_conversation_interaction(
               handle,
               {:approval, interaction},
               10_000
             )

    assert {:ok, record} = DurableStore.get(receipt.request_id)
    assert {:ok, _json} = Jason.encode(record.data)
    metadata = record.data["interaction"]["metadata"]
    assert metadata["task_id"] == identity.task_id
    assert metadata["capability_id"] == "cap_original"
    assert metadata["display"]["trust"] == %{"effective_mode" => "ask"}
    refute inspect(metadata) =~ "operation_taint"

    assert {:ok, %{interactions: [prompt]}} =
             Arbor.Comms.conversation_interactions(ctx.scope, ctx.command.id)

    assert prompt.text =~ "echo reviewed-command"
    assert prompt.text =~ "capability_requires_approval"
    assert prompt.text =~ "ask"

    assert {:error, :scoped_answer_required} =
             Arbor.Comms.respond_to_interaction(receipt.request_id, :approved)
  end

  test "security regression: attached approval never dispatches to a separately configured operator",
       ctx do
    operator = Humans.human!()

    {:ok, identity} =
      ConversationJournal.validate_binding(ctx.binding, ctx.scope, ctx.command.text)

    {:ok, _} = Arbor.Comms.track_presence(self(), operator, :dashboard, %{test_pid: self()})
    on_exit(fn -> Arbor.Comms.untrack_presence(self(), operator, :dashboard) end)
    set_env(:arbor_comms, :interaction_adapters, %{dashboard: DeliveryWitnessAdapter})

    {:ok, interaction} =
      Arbor.Contracts.Comms.Interaction.new(%{
        kind: :approval,
        agent_id: ctx.scope.agent_id,
        user_id: operator,
        description: "Only the source conversation owner may read this approval",
        resource_uri: "arbor://action/test/no_legacy_dispatch",
        metadata: %{task_id: identity.task_id, principal_id: ctx.scope.agent_id}
      })

    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())

    {:ok, receipt} =
      Arbor.Comms.request_conversation_interaction(handle, {:approval, interaction}, 10_000)

    refute_receive {:legacy_source_delivery, _}, 50
    assert {:error, :scoped_delivery_required} = Authority.claim_dispatch(receipt.request_id)
    assert :empty = Authority.claim_next_dispatch()
    assert :ok = Arbor.Comms.InteractionRegistry.Dispatcher.sweep_now()

    Arbor.Comms.InteractionRegistry.Dispatcher.wake(receipt.request_id, %{
      dashboard: DeliveryWitnessAdapter
    })

    refute_receive {:legacy_source_delivery, _}, 50
    assert {:ok, :pending} = Authority.status(receipt.request_id)
  end

  test "security regression: chat revocation after source creation cannot leak a prompt through a later legacy sweep",
       ctx do
    {:ok, _} =
      Arbor.Comms.track_presence(self(), ctx.human.human_id, :dashboard, %{test_pid: self()})

    on_exit(fn -> Arbor.Comms.untrack_presence(self(), ctx.human.human_id, :dashboard) end)
    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())
    {:ok, receipt} = Arbor.Comms.request_conversation_interaction(handle, spec(), 10_000)
    assert :ok = Arbor.Security.revoke_fixture(ctx.chat_cap.id)

    assert {:error, _} =
             Arbor.Security.recheck_conversation_owner(
               ctx.human.human_id,
               ctx.scope.agent_id,
               ctx.scope.principal_id
             )

    set_env(:arbor_comms, :interaction_adapters, %{dashboard: DeliveryWitnessAdapter})
    # Let an earlier no-adapter attempt become due in the original implementation.
    Process.sleep(20)
    assert :ok = Arbor.Comms.InteractionRegistry.Dispatcher.sweep_now()

    Arbor.Comms.InteractionRegistry.Dispatcher.wake(receipt.request_id, %{
      dashboard: DeliveryWitnessAdapter
    })

    refute_receive {:legacy_source_delivery, _}, 50
    assert {:error, :scoped_delivery_required} = Authority.claim_dispatch(receipt.request_id)
    assert :empty = Authority.claim_next_dispatch()
  end

  test "security regression: terminal history cannot hide a fresh pending source prompt in bounded discovery",
       ctx do
    {:ok, identity} =
      ConversationJournal.validate_binding(ctx.binding, ctx.scope, ctx.command.text)

    make_interaction = fn id ->
      {:ok, interaction} =
        Arbor.Contracts.Comms.Interaction.new(%{
          request_id: id,
          kind: :approval,
          agent_id: ctx.scope.agent_id,
          user_id: ctx.human.human_id,
          description: "Discover the live source approval",
          resource_uri: "arbor://action/test/discovery",
          metadata: %{task_id: identity.task_id, principal_id: ctx.scope.agent_id}
        })

      interaction
    end

    for number <- 1..32 do
      {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())
      id = "a_" <> String.pad_leading(to_string(number), 2, "0")

      assert {:ok, %{request_id: ^id}} =
               Arbor.Comms.request_conversation_interaction(
                 handle,
                 {:approval, make_interaction.(id)},
                 10_000
               )

      assert :ok = Arbor.Comms.retire_conversation_source(handle, :source_retired)
    end

    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())

    assert {:ok, %{request_id: "z_01"}} =
             Arbor.Comms.request_conversation_interaction(
               handle,
               {:approval, make_interaction.("z_01")},
               10_000
             )

    assert {:ok, %{interactions: [pending | history]}} =
             Arbor.Comms.conversation_interactions(ctx.scope, ctx.command.id)

    assert pending.request_id == "z_01"
    assert pending.status == :pending
    assert length(history) == 31
    assert Enum.all?(history, &(&1.status == :abandoned))
    assert Enum.map(history, & &1.request_id) == Enum.sort(Enum.map(history, & &1.request_id))
  end

  test "security regression: protected source refuses raw and choice routes and requires general human approval authority",
       ctx do
    {:ok, identity} =
      ConversationJournal.validate_binding(ctx.binding, ctx.scope, ctx.command.text)

    {:ok, interaction} =
      Arbor.Contracts.Comms.Interaction.new(%{
        kind: :approval,
        agent_id: ctx.scope.agent_id,
        user_id: ctx.human.human_id,
        description: "Review the source action",
        resource_uri: "arbor://action/test/source",
        metadata: %{task_id: identity.task_id, principal_id: ctx.scope.agent_id}
      })

    {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())

    {:ok, receipt} =
      Arbor.Comms.request_conversation_interaction(handle, {:approval, interaction}, 10_000)

    assert {:error, :scoped_answer_required} =
             Arbor.Comms.respond_to_interaction(receipt.request_id, :approved)

    assert {:error, _} =
             Arbor.Comms.respond_conversation_interaction(
               ctx.scope,
               answer(ctx, receipt, "approve"),
               ctx.human.human_id,
               %{}
             )

    operation = %{
      command_id: ctx.command.id,
      request_id: receipt.request_id,
      operation_id: receipt.operation_id,
      revision: 1,
      decision: "approve",
      note: nil
    }

    proof =
      proof(ctx, operation, :interaction_approval) |> Map.put(:session_token, ctx.human.token)

    assert {:error, :approval_answer_required} =
             Arbor.Comms.respond_conversation_interaction(
               ctx.scope,
               operation,
               ctx.human.human_id,
               proof
             )

    assert {:ok, :pending} = Authority.status(receipt.request_id)
    Humans.grant!(ctx.human.human_id, "arbor://approval/answer/" <> ctx.scope.agent_id)

    {:ok, chat_token} =
      Arbor.Security.issue_conversation_session_fixture(ctx.human.human_id, ctx.scope.agent_id)

    chat_ctx = %{ctx | human: %{ctx.human | token: chat_token}}

    chat_proof =
      proof(chat_ctx, operation, :interaction_approval) |> Map.put(:session_token, chat_token)

    assert {:error, :approval_answer_required} =
             Arbor.Comms.respond_conversation_interaction(
               ctx.scope,
               operation,
               ctx.human.human_id,
               chat_proof
             )

    assert {:ok, :pending} = Authority.status(receipt.request_id)

    proof =
      proof(ctx, operation, :interaction_approval) |> Map.put(:session_token, ctx.human.token)

    assert {:ok, %{status: :responded}} =
             Arbor.Comms.respond_conversation_interaction(
               ctx.scope,
               operation,
               ctx.human.human_id,
               proof
             )

    restart_authority()

    assert {:ok, %{verified_human_id: human}} =
             Arbor.Comms.get_answered_approval(receipt.request_id)

    assert human == ctx.human.human_id
  end

  test "security regression: durable deny approval answers preserve JSON metadata and the exact human decision",
       ctx do
    assert_rejected_answers(ctx, :deny)
  end

  test "security regression: durable rework approval answers preserve JSON metadata and the exact human decision",
       ctx do
    assert_rejected_answers(ctx, :rework)
  end

  defp assert_rejected_answers(ctx, expected_decision) do
    {:ok, identity} =
      ConversationJournal.validate_binding(ctx.binding, ctx.scope, ctx.command.text)

    Humans.grant!(ctx.human.human_id, "arbor://approval/answer/" <> ctx.scope.agent_id)

    answered =
      for {decision, note} <- [
            {expected_decision, nil},
            {Atom.to_string(expected_decision), "Review this rejected request 🌲 東京"}
          ] do
        {:ok, interaction} =
          Arbor.Contracts.Comms.Interaction.new(%{
            kind: :approval,
            agent_id: ctx.scope.agent_id,
            user_id: ctx.human.human_id,
            description: "Review the durable rejection decision",
            resource_uri: "arbor://action/test/rejected_source",
            metadata: %{task_id: identity.task_id, principal_id: ctx.scope.agent_id}
          })

        {:ok, handle} = Arbor.Comms.open_conversation_source(ctx.binding, self(), make_ref())

        {:ok, receipt} =
          Arbor.Comms.request_conversation_interaction(handle, {:approval, interaction}, 10_000)

        operation = %{
          command_id: ctx.command.id,
          request_id: receipt.request_id,
          operation_id: receipt.operation_id,
          revision: 1,
          decision: decision,
          note: note
        }

        proof =
          proof(ctx, operation, :interaction_approval) |> Map.put(:session_token, ctx.human.token)

        assert {:ok, %{request_id: request_id, status: :responded}} =
                 Arbor.Comms.respond_conversation_interaction(
                   ctx.scope,
                   operation,
                   ctx.human.human_id,
                   proof
                 )

        assert request_id == receipt.request_id

        assert {:ok, %{response: :rejected, metadata: metadata}} =
                 Arbor.Comms.get_interaction_response(receipt.request_id)

        assert metadata["decision"] == to_string(decision)
        assert metadata["note"] == note

        assert {:error, _} =
                 Arbor.Comms.respond_conversation_interaction(
                   ctx.scope,
                   operation,
                   ctx.human.human_id,
                   proof
                 )

        {receipt.request_id, expected_decision}
      end

    restart_authority()

    for {request_id, decision} <- answered do
      assert {:ok, evidence} = Arbor.Comms.get_answered_approval(request_id)
      assert evidence.decision == decision
      assert evidence.verified_human_id == ctx.human.human_id
      assert evidence.agent_id == ctx.scope.agent_id
      assert evidence.resource_uri == "arbor://action/test/rejected_source"
    end
  end

  defp spec,
    do: %{
      kind: :choice,
      text: "Choose",
      choices: [%{id: "choice_1", label: "Same"}, %{id: "choice_2", label: "Same"}]
    }

  defp answer(ctx, receipt, choice),
    do: %{
      command_id: ctx.command.id,
      request_id: receipt.request_id,
      operation_id: receipt.operation_id,
      revision: 1,
      choice_id: choice
    }

  defp proof(ctx, operation, kind) do
    {:ok, payload} =
      Arbor.Comms.conversation_interaction_request_payload(
        kind,
        ctx.human.human_id,
        ctx.scope.agent_id,
        operation,
        ctx.scope.engagement_id
      )

    {:ok, receipt} =
      Arbor.Security.authorize_and_issue_conversation_operation_receipt(
        ctx.human.human_id,
        "arbor://chat/agent/" <> ctx.scope.agent_id,
        payload,
        session_token: ctx.human.token,
        expected_engagement_id: ctx.scope.engagement_id
      )

    %{receipt: receipt, expected_engagement_id: ctx.scope.engagement_id}
  end

  defp set_env(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp restart_authority do
    if Process.whereis(Arbor.Comms.Supervisor) do
      :ok = Supervisor.terminate_child(Arbor.Comms.Supervisor, InteractionRegistry)
      {:ok, _} = Supervisor.restart_child(Arbor.Comms.Supervisor, InteractionRegistry)
    end
  end

  defp assert_eventually(fun, remaining \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          assert_eventually(fun, remaining - 1)
        )
  end
end
