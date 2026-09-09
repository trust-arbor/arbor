defmodule Arbor.Orchestrator.Session.TranscriptRecoveryTest do
  @moduledoc """
  Standalone SQLite proof: public Session turns commit through Persistence, then
  Session and its owned Repo are stopped and recreated from the same database.
  This proves process/storage reopen, not whole-BEAM, node, or host loss.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo

  @moduletag :isolated_repo
  @moduletag :database
  @moduletag :sqlite
  @moduletag :integration
  @migrations_path Path.expand("../../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  if Repo.__adapter__() != Ecto.Adapters.SQLite3 do
    @moduletag skip: "requires the compiled SQLite Repo adapter"
  end

  defmodule Probe do
    use Agent

    def start_link(parent), do: Agent.start_link(fn -> parent end, name: __MODULE__)
    def parent, do: Agent.get(__MODULE__, & &1)
  end

  defmodule CaptureProvider do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "lm_studio"

    @impl true
    def complete(%Request{} = request, _opts) do
      users = request.messages |> Enum.filter(&(&1.role == :user)) |> Enum.map(& &1.content)
      send(Probe.parent(), {:provider_prompt, users})

      if List.last(users) in ["hold-old", "hold-new"] do
        send(Probe.parent(), {:provider_held, List.last(users), self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "test provider was not released"
        end
      end

      {:ok,
       %Response{
         text: "local-response",
         finish_reason: :stop,
         content_parts: [ContentPart.text("local-response")],
         usage: %{input_tokens: 1, output_tokens: 1},
         raw: %{}
       }}
    end

    @impl true
    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  setup do
    assert GenServer.whereis(Repo) == nil,
           "run this isolated Repo proof standalone, with no existing Repo"

    root =
      Path.join(System.tmp_dir!(), "session-recovery-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    turn_path = Path.join(root, "turn.dot")
    File.write!(turn_path, turn_dot())

    repo_opts = [
      database: Path.join(root, "transcript.sqlite3"),
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 5_000,
      journal_mode: :wal
    ]

    start_supervised!({Repo, repo_opts})
    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations_path, :up, all: true, log: false)
    start_supervised!({Probe, self()})

    previous_client = previous_client()

    client =
      Client.new(default_provider: CaptureProvider.provider(), model_catalog: %{})
      |> Client.register_adapter(CaptureProvider)

    :ok = Client.set_default_client(client)

    on_exit(fn ->
      if previous_client,
        do: Client.set_default_client(previous_client),
        else: Client.clear_default_client()
    end)

    agent_id = "agent_recovery_#{System.unique_integer([:positive])}"

    assert {:ok, capability} =
             Arbor.Security.grant(
               principal: agent_id,
               resource: "arbor://orchestrator/execute/**"
             )

    on_exit(fn -> Arbor.Security.revoke(capability.id) end)

    %{
      agent_id: agent_id,
      session_id: "session-#{agent_id}",
      turn_path: turn_path,
      repo_opts: repo_opts
    }
  end

  test "cold Session and SQLite reopen restores only the selected transcript with its taint",
       ctx do
    test_pid = self()

    adapters = %{
      checkpoint_save: fn session_id, data ->
        send(test_pid, {:retired_snapshot_writer, session_id, data})
        :ok
      end
    }

    old = start_session!(ctx, adapters: adapters)
    send_turn!(old, "eng_alpha", "alpha durable fact")
    assert_prompt(["alpha durable fact"])
    send_turn!(old, "eng_beta", "beta private fact")
    assert_prompt(["beta private fact"])

    [old_user, old_assistant] = load_messages(ctx, "eng_alpha")
    assert %Taint{} = old_user.taint
    assert %Taint{} = old_assistant.taint
    assert old_user.taint_status == :verified
    refute_receive {:retired_snapshot_writer, _, _}, 100

    GenServer.stop(old)
    assert :ok = stop_supervised(Repo)
    start_supervised!({Repo, ctx.repo_opts})

    restored = start_session!(ctx, adapters: adapters)
    assert Session.get_state(restored).messages == []
    send_turn!(restored, "eng_alpha", "alpha after reopen")
    assert_prompt(["alpha durable fact", "alpha after reopen"])

    [restored_user, restored_assistant | _] = Session.get_state(restored).messages
    assert restored_user["taint"] == old_user.taint
    assert restored_user["taint_status"] == old_user.taint_status
    assert restored_assistant["taint"] == old_assistant.taint
    assert restored_assistant["taint_status"] == old_assistant.taint_status

    send_turn!(restored, "eng_beta", "beta after reopen")
    assert_prompt(["beta private fact", "beta after reopen"])
    assert length(load_messages(ctx, "eng_alpha")) == 4
    assert length(load_messages(ctx, "eng_beta")) == 4
    refute_receive {:retired_snapshot_writer, _, _}, 100
  end

  test "recovery opt-out prevents the read and unscoped history is never used as fallback", ctx do
    test_pid = self()
    old = start_session!(ctx)
    send_turn!(old, "eng_alpha", "stored named fact")
    assert_prompt(["stored named fact"])
    send_turn!(old, nil, "stored unscoped fact")
    assert_prompt(["stored unscoped fact"])
    GenServer.stop(old)

    adapters = %{
      load_recent_session_messages: fn session_id, opts ->
        send(test_pid, :recovery_read)
        Arbor.Persistence.load_recent_session_messages(session_id, opts)
      end
    }

    disabled = start_session!(ctx, adapters: adapters, recover_session: false)
    send_turn!(disabled, "eng_alpha", "fresh opted-out turn")
    assert_prompt(["fresh opted-out turn"])
    refute_receive :recovery_read, 100
    GenServer.stop(disabled)

    restored = start_session!(ctx)
    send_turn!(restored, nil, "fresh unscoped turn")
    assert_prompt(["fresh unscoped turn"])
  end

  test "unavailable recovery backend cannot acknowledge or adopt an uncommitted turn", ctx do
    old = start_session!(ctx)
    send_turn!(old, "eng_alpha", "previously committed")
    assert_prompt(["previously committed"])
    before = load_messages(ctx, "eng_alpha")
    GenServer.stop(old)
    assert :ok = stop_supervised(Repo)

    unavailable = start_session!(ctx)

    assert {:error, :turn_commit_failed} =
             Session.send_message(unavailable, message("eng_alpha", "uncommitted input"))

    assert_prompt(["uncommitted input"])
    state = Session.get_state(unavailable)
    assert state.messages == []
    assert state.turn_count == 0
    refute state.turn_in_flight
    GenServer.stop(unavailable)

    start_supervised!({Repo, ctx.repo_opts})
    assert load_messages(ctx, "eng_alpha") == before
  end

  test "a held completion from the previous Session cannot commit over the replacement", ctx do
    task_supervisor = Session.TaskSupervisor

    unless Process.whereis(task_supervisor), do: start_supervised!(task_supervisor)

    old = start_session!(ctx)
    old_caller = request_turn(old, "hold-old")
    assert_prompt(["hold-old"])
    assert_receive {:provider_held, "hold-old", old_worker}, 2_000
    on_exit(fn -> stop_process(old_worker) end)

    # Hold the actual completed Engine envelope before its original Session can
    # consume it. Replaying this observed old message tests the incarnation fence.
    :ok = :sys.suspend(old)
    {:monitors, monitors} = Process.info(old, :monitors)

    [engine_task] =
      task_supervisor
      |> Task.Supervisor.children()
      |> Enum.filter(&({:process, &1} in monitors))

    on_exit(fn -> stop_process(engine_task) end)
    trace = :trace.session_create(__MODULE__, self(), [])

    stale_completion =
      try do
        assert 1 = :trace.process(trace, engine_task, true, [:send])
        send(old_worker, :release)

        assert_receive {:trace, ^engine_task, :send,
                        {:turn_result, token, %UserMessage{}, {:ok, result}} = completed, ^old},
                       5_000

        assert is_reference(token)
        assert result.final_outcome.status == :success
        completed
      after
        :trace.session_destroy(trace)
      end

    stop_process(old)
    assert {:error, :session_stopped} = Task.await(old_caller, 2_000)
    assert load_messages(ctx, "eng_alpha") == []

    replacement = start_session!(ctx)
    new_caller = request_turn(replacement, "hold-new")
    assert_prompt(["hold-new"])
    assert_receive {:provider_held, "hold-new", new_worker}, 2_000
    on_exit(fn -> stop_process(new_worker) end)
    send(replacement, stale_completion)

    # The public call is a mailbox barrier after the stale completion above.
    assert Session.get_state(replacement).turn_in_flight
    assert load_messages(ctx, "eng_alpha") == []
    send(new_worker, :release)
    assert {:ok, %{content: "local-response"}} = Task.await(new_caller, 5_000)

    [user, assistant] = load_messages(ctx, "eng_alpha")
    assert user.content == "hold-new"
    assert assistant.content == "local-response"
    assert Session.get_state(replacement).turn_count == 1
  end

  defp previous_client do
    Client.default_client()
  rescue
    Arbor.LLM.ConfigurationError -> nil
  end

  defp start_session!(ctx, opts \\ []) do
    config = %{
      "llm_provider" => "lmstudio",
      "llm_model" => "deterministic-recovery-test",
      "stream" => false,
      "recover_session" => Keyword.get(opts, :recover_session, true)
    }

    assert {:ok, pid} =
             Session.start_link(
               agent_id: ctx.agent_id,
               session_id: ctx.session_id,
               turn_dot: ctx.turn_path,
               start_heartbeat: false,
               config: config,
               adapters: Keyword.get(opts, :adapters, %{})
             )

    Process.unlink(pid)
    on_exit(fn -> stop_process(pid) end)
    pid
  end

  defp stop_process(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
  end

  defp send_turn!(pid, engagement, text) do
    assert {:ok, %{content: "local-response"}} =
             Session.send_message(pid, message(engagement, text))
  end

  defp request_turn(pid, text) do
    Task.async(fn ->
      try do
        Session.send_message(pid, message("eng_alpha", text))
      catch
        :exit, _ -> {:error, :session_stopped}
      end
    end)
  end

  defp message(engagement, text) do
    text |> UserMessage.from_string() |> UserMessage.with_engagement(engagement)
  end

  defp assert_prompt(expected) do
    assert_receive {:provider_prompt, ^expected}, 5_000
  end

  defp load_messages(ctx, engagement) do
    Arbor.Persistence.load_recent_session_messages(ctx.session_id, engagement_id: engagement)
  end

  defp turn_dot do
    """
    digraph TranscriptRecovery {
      start [shape=Mdiamond]
      llm [type="compute", simulate="false", prompt_context_key="session.input",
           messages_context_key="session.messages"]
      format [type="transform", transform="identity", source_key="last_response",
              output_key="session.response"]
      done [shape=Msquare]
      start -> llm -> format -> done
    }
    """
  end
end
