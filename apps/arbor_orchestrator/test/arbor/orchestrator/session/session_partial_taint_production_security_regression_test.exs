defmodule Arbor.Orchestrator.Session.SessionPartialTaintProductionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Persistence

  @moduletag :fast
  @moduletag :security_regression

  defmodule ControlledAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @state_key {__MODULE__, :state}

    def configure(parent, mode), do: :persistent_term.put(@state_key, {parent, mode})
    def clear, do: :persistent_term.erase(@state_key)

    @impl true
    def provider, do: "lm_studio"

    @impl true
    def complete(%Request{} = request, _opts) do
      {parent, mode} = :persistent_term.get(@state_key)
      send(parent, {:partial_provider_started, self(), request})

      case mode do
        :fail ->
          receive do
            :fail_now -> {:error, :simulated_provider_failure}
          end

        blocked when blocked in [:cancel, :timeout] ->
          receive do
            :unexpected_release -> response()
          end
      end
    end

    @impl true
    def complete_single_attempt(request, opts), do: complete(request, opts)

    defp response do
      {:ok,
       %Response{
         text: "unexpected completion",
         finish_reason: :stop,
         content_parts: [ContentPart.text("unexpected completion")],
         usage: %{input_tokens: 1, output_tokens: 1},
         raw: %{}
       }}
    end
  end

  setup do
    client =
      Client.new(default_provider: ControlledAdapter.provider(), model_catalog: %{})
      |> Client.register_adapter(ControlledAdapter)

    :ok = Client.set_default_client(client)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_partial_taint_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    turn_path = Path.join(tmp_dir, "turn.dot")
    File.write!(turn_path, turn_dot())

    on_exit(fn ->
      ControlledAdapter.clear()
      Client.clear_default_client()
      File.rm_rf(tmp_dir)
    end)

    %{turn_path: turn_path}
  end

  for mode <- [:cancel, :timeout, :fail] do
    test "security regression: production #{mode} partial preserves hostile input evidence",
         ctx do
      exercise_partial_mode(unquote(mode), ctx)
    end
  end

  defp exercise_partial_mode(mode, ctx) do
    ControlledAdapter.configure(self(), mode)
    {pid, engagement_id} = start_hostile_session!(ctx, mode)

    caller =
      Task.async(fn ->
        message =
          UserMessage.from_string("interrupted current input")
          |> UserMessage.with_engagement(engagement_id)

        Session.send_message(pid, message)
      end)

    assert_receive {:partial_provider_started, provider_pid, request}, 2_000
    assert Enum.all?(request.messages, &(&1.metadata == %{}))

    send(pid, {:stream_chunk, "partial source-owned output"})
    assert Session.get_state(pid).streaming_buffer.content == "partial source-owned output"

    case mode do
      :cancel -> assert :ok = Session.cancel_turn(pid)
      :timeout -> :ok
      :fail -> send(provider_pid, :fail_now)
    end

    assert {:error, _reason} = Task.await(caller, 3_000)
    assert_hostile_partial_batch(engagement_id)
  end

  defp start_hostile_session!(ctx, mode) do
    parent = self()
    suffix = System.unique_integer([:positive, :monotonic])
    agent_id = "agent_partial_taint_#{suffix}"
    session_id = "session-partial-taint-#{suffix}"
    engagement_id = "eng-partial-taint"
    hostile = taint("restored_partial_hostile", :hostile)

    checkpoint =
      Persistence.extract_checkpoint_data(%Session{
        session_id: session_id,
        agent_id: agent_id,
        current_engagement_id: engagement_id,
        messages: [
          %{
            "role" => "user",
            "content" => "hostile prior input",
            "taint" => hostile,
            "taint_status" => :verified
          }
        ]
      })

    adapters = %{
      ensure_session: fn ^session_id, ^agent_id, [] -> {:ok, %{id: session_id}} end,
      append_session_entries: fn ^session_id, entries ->
        send(parent, {:partial_taint_batch, entries})
        {:ok, length(entries)}
      end,
      load_recent_session_messages: fn ^session_id, _opts -> [] end
    }

    timeout_ms = if mode == :timeout, do: 250, else: 5_000

    Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(agent_id)
    on_exit(fn -> Arbor.Orchestrator.TestCapabilities.revoke_all(agent_id) end)

    assert {:ok, pid} =
             Session.start_link(
               session_id: session_id,
               agent_id: agent_id,
               turn_dot: ctx.turn_path,
               checkpoint: checkpoint,
               adapters: adapters,
               config: %{
                 "llm_provider" => "lmstudio",
                 "llm_model" => "partial-security-model",
                 "stream" => false,
                 turn_timeout_ms: timeout_ms
               },
               start_heartbeat: false
             )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, engagement_id}
  end

  defp assert_hostile_partial_batch(engagement_id) do
    assert_receive {:partial_taint_batch, [user_entry, assistant_entry]}, 1_000
    assert user_entry.metadata["engagement_id"] == engagement_id
    assert assistant_entry.metadata["engagement_id"] == engagement_id

    for entry <- [user_entry, assistant_entry] do
      assert {:ok, envelope} = TaintEnvelope.verify(entry.metadata["taint"], entry.content)
      assert envelope.taint.level == :hostile
      assert envelope.taint.sensitivity == :restricted
    end
  end

  defp taint(source, level) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: source,
        chain: []
      })

    taint
  end

  defp turn_dot do
    """
    digraph SessionPartialTaintProductionSecurityRegression {
      graph [goal="Partial taint production path"]
      start [shape=Mdiamond]
      call_llm [
        type="compute",
        simulate="false",
        prompt_context_key="session.input",
        messages_context_key="session.messages"
      ]
      format [
        type="transform",
        transform="identity",
        source_key="last_response",
        output_key="session.response"
      ]
      done [shape=Msquare]
      start -> call_llm -> format -> done
    }
    """
  end
end
