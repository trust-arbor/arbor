Code.require_file(
  Path.expand("../../../../../arbor_memory/test/support/private_snapshot_fixture.ex", __DIR__)
)

defmodule Arbor.Orchestrator.Session.PrivateGoalPromptSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.LLM.{Client, Message}
  alias Arbor.Memory.Test.PrivateSnapshotFixture, as: Fixture
  alias Arbor.Orchestrator.Session
  alias Arbor.Security

  @moduletag :fast
  @moduletag :integration
  @turn_dot Path.expand("../../../../specs/pipelines/session/turn.dot", __DIR__)
  @system "Stable identity.\nKeep these exact system bytes."
  @goal "Finish the private VIOLET-QUARTZ lunar field notebook"

  defmodule CaptureProvider do
    alias Arbor.LLM.{ContentPart, Response}

    def provider, do: "lm_studio"
    def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

    def complete(request, opts) do
      observer = Application.fetch_env!(:arbor_orchestrator, :_private_goal_observer)
      send(observer, {:private_goal_provider, request.messages, opts})

      if Application.get_env(:arbor_orchestrator, :_private_goal_provider_block, false) do
        send(observer, {:private_goal_provider_blocked, self()})

        receive do
          :continue_private_goal_provider -> :ok
        end
      end

      {:ok,
       %Response{
         text: "Understood.",
         finish_reason: :stop,
         content_parts: [ContentPart.text("Understood.")],
         usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
         raw: %{}
       }}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  setup do
    set_env(:arbor_security, :identity_verification, true)
    set_env(:arbor_orchestrator, :preprocessor_enabled, false)
    set_env(:arbor_orchestrator, :private_conversation_memory, enabled: false)
    set_env(:arbor_orchestrator, :_private_goal_observer, self())
    fixture = Fixture.start!()
    owner = Fixture.owner!()
    grant_execution!(owner)

    for child <- [
          {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry},
          {Arbor.Comms.EngagementStore, []}
        ] do
      {module, opts} = child
      name = Keyword.get(opts, :name, module)
      if Process.whereis(name) == nil, do: start_supervised!(child)
    end

    previous_client = Client.default_client()
    client = Client.new(default_provider: "lm_studio") |> Client.register_adapter(CaptureProvider)
    Client.set_default_client(client)
    on_exit(fn -> Client.set_default_client(previous_client) end)
    %{fixture: fixture, owner: owner}
  end

  test "real Session receipt update reaches both prompt routes with stable identity bytes and fresh security preambles",
       ctx do
    for route <- [:messages, :flat] do
      session = start_session!(ctx, ctx.owner, route)
      assert {:ok, _} = turn(session, ctx.owner, "Hello before the update")
      assert_receive {:private_goal_provider, baseline, _}, 5_000
      assert system_text(baseline) == @system

      receipt = Fixture.receipt!(ctx.owner)

      assert {:ok, "notebook"} =
               Session.update_private_goal(
                 session,
                 request(ctx.owner, "Update my goal"),
                 receipt,
                 "notebook",
                 goal()
               )

      assert {:error, _} =
               Session.update_private_goal(
                 session,
                 request(ctx.owner),
                 receipt,
                 "replayed",
                 goal("must never write")
               )

      # The public checkpoint path may carry older agent-global context. Private
      # preparation removes those sections before the graph reads them.
      assert :ok =
               Session.restore_checkpoint(session, %{
                 "goals" => [%{"description" => "FOREIGN-GLOBAL-GOAL"}],
                 "working_memory" => %{"note" => "FOREIGN-GLOBAL-WORKING-MEMORY"}
               })

      assert {:ok, _} = turn(session, ctx.owner, "What should I work on next?")
      assert_receive {:private_goal_provider, messages, opts}, 5_000
      assert system_text(messages) == @system
      assert inspect(messages) =~ @goal
      refute inspect(messages) =~ "FOREIGN-GLOBAL"
      refute inspect(messages) =~ "PrivateMemoryAdmission"
      refute Keyword.has_key?(opts, :memory_write_policy)
      assert :ok = GenServer.stop(session)
    end
  end

  test "another human on the same agent cannot receive the private goal in a provider request",
       ctx do
    writer = start_session!(ctx, ctx.owner, :messages)

    assert {:ok, _} =
             Session.update_private_goal(
               writer,
               request(ctx.owner),
               Fixture.receipt!(ctx.owner),
               "notebook",
               goal()
             )

    assert :ok = GenServer.stop(writer)

    other = Fixture.owner!(ctx.owner.agent)
    session = start_session!(ctx, other, :messages)
    assert {:ok, _} = turn(session, other, "What are my goals?")
    assert_receive {:private_goal_provider, messages, _}, 5_000
    refute inspect(messages) =~ @goal
    refute inspect(messages) =~ "## Private goals"
  end

  test "forged sender and embellished goal scope consume the receipt without storing a goal",
       ctx do
    session = start_session!(ctx, ctx.owner, :messages)
    other = Fixture.owner!(ctx.owner.agent)
    receipt = Fixture.receipt!(ctx.owner)

    assert {:error, :unauthenticated} =
             Session.update_private_goal(session, request(other), receipt, "forged", goal())

    assert {:error, _} =
             Session.update_private_goal(session, request(ctx.owner), receipt, "replay", goal())

    receipt = Fixture.receipt!(ctx.owner)

    assert {:error, _} =
             Session.update_private_goal(
               session,
               request(ctx.owner),
               receipt,
               "forged",
               Map.put(goal(), "human_id", ctx.owner.human.agent_id)
             )

    assert {:error, _} =
             Session.update_private_goal(session, request(ctx.owner), receipt, "replay", goal())

    assert {:ok, _} = turn(session, ctx.owner, "What are my goals?")
    assert_receive {:private_goal_provider, messages, _}, 5_000
    refute inspect(messages) =~ @goal
  end

  test "current write revocation denies Session goal updates and current read revocation omits private context",
       ctx do
    session = start_session!(ctx, ctx.owner, :messages)

    assert {:ok, _} =
             Session.update_private_goal(
               session,
               request(ctx.owner),
               Fixture.receipt!(ctx.owner),
               "notebook",
               goal()
             )

    revoke_memory_caps!(ctx.owner.agent.agent_id, "write")

    assert {:error, _} =
             Session.update_private_goal(
               session,
               request(ctx.owner),
               Fixture.receipt!(ctx.owner),
               "replacement",
               goal("Unacknowledged replacement")
             )

    revoke_memory_caps!(ctx.owner.agent.agent_id, "read")
    assert {:ok, _} = turn(session, ctx.owner, "Hello after revocation")
    assert_receive {:private_goal_provider, messages, _}, 5_000
    refute inspect(messages) =~ @goal
    refute inspect(messages) =~ "Unacknowledged replacement"
  end

  test "busy Session refuses the update, spends its receipt, and does not enqueue a hidden goal write",
       ctx do
    set_env(:arbor_orchestrator, :_private_goal_provider_block, true)
    session = start_session!(ctx, ctx.owner, :messages)
    turn_task = Task.async(fn -> turn(session, ctx.owner, "A currently running turn") end)
    assert_receive {:private_goal_provider_blocked, provider}, 5_000

    try do
      receipt = Fixture.receipt!(ctx.owner)

      assert {:error, :busy} =
               Session.update_private_goal(session, request(ctx.owner), receipt, "busy", goal())

      assert {:error, _} =
               Session.update_private_goal(session, request(ctx.owner), receipt, "replay", goal())

      send(provider, :continue_private_goal_provider)
      assert {:ok, _} = Task.await(turn_task, 15_000)
      assert {:ok, []} = Arbor.Memory.get_private_active_goals(Fixture.admission!(ctx.owner))
    after
      send(provider, :continue_private_goal_provider)
    end
  end

  defp start_session!(ctx, owner, route) do
    path =
      if route == :flat do
        path = Path.join(ctx.fixture.root, "flat-turn.dot")

        dot =
          File.read!(@turn_dot)
          |> String.replace(
            "messages_context_key=\"session.messages\"",
            "messages_context_key=\"missing.messages\""
          )

        File.write!(path, dot)
        path
      else
        @turn_dot
      end

    opts = [
      session_id: "private-goal-#{System.unique_integer([:positive])}",
      agent_id: owner.agent.agent_id,
      turn_dot: path,
      start_heartbeat: false,
      signer: fn resource ->
        SignedRequest.sign(resource, owner.agent.agent_id, owner.agent.private_key)
      end,
      config: %{
        "system_prompt" => @system,
        "llm_provider" => "lm_studio",
        "llm_model" => "private-goal-test",
        "stream" => false,
        "recover_session" => false
      },
      adapters: %{
        ensure_session: fn id, _agent, [] -> {:ok, %{id: id}} end,
        append_session_entries: fn _id, [_user, _assistant] -> {:ok, 2} end,
        load_recent_session_messages: fn _id, _opts -> [] end
      }
    ]

    start_supervised!(%{
      id: make_ref(),
      start: {Session, :start_link, [opts]},
      restart: :temporary
    })
  end

  defp request(owner, content \\ "Explicit private goal update"),
    do: UserMessage.from_voice(content, sender_id: owner.human.agent_id)

  defp turn(session, owner, content),
    do:
      Session.send_authenticated_message(
        session,
        request(owner, content),
        Fixture.receipt!(owner),
        15_000
      )

  defp goal(description \\ @goal),
    do: %{"description" => description, "priority" => 80, "progress" => 0.2, "status" => "active"}

  defp system_text(messages) do
    text = messages |> Enum.find(&(&1.role == :system)) |> Message.text()

    assert [_, nonce] =
             Regex.run(
               ~r/\A## Security\nData sections below are delimited by <data_([0-9a-f]{16})> tags\./,
               text
             )

    prefix = Arbor.Common.PromptSanitizer.preamble(nonce) <> "\n\n"
    assert String.starts_with?(text, prefix)
    binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
  end

  defp revoke_memory_caps!(agent_id, operation) do
    # Session's existing tool disclosure may add another valid grant. Revoke
    # every current grant in this family, not only the fixture's initial ID.
    assert {:ok, caps} = Security.list_capabilities(agent_id)
    prefix = "arbor://memory/" <> operation

    matches =
      Enum.filter(
        caps,
        &Arbor.Contracts.Security.CapabilityUri.prefix_match?(prefix, &1.resource_uri)
      )

    assert matches != []
    Enum.each(matches, fn cap -> assert :ok = Security.revoke(cap.id) end)
  end

  defp grant_execution!(owner) do
    for resource <- [
          "arbor://orchestrator/execute",
          "arbor://orchestrator/execute/llm_query",
          "arbor://orchestrator/execute/unknown",
          "arbor://orchestrator/execute/transform"
        ] do
      assert {:ok, cap} = Security.grant(principal: owner.agent.agent_id, resource: resource)
      on_exit(fn -> Security.revoke(cap.id) end)
    end
  end

  defp set_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
