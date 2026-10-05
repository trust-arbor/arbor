Code.require_file("../../support/conversation_journal_sqlite.exs", __DIR__)

defmodule Arbor.Comms.ConversationJournalTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.ConversationJournal, as: Journal
  alias Arbor.Comms.ConversationJournalCore, as: Core
  alias Arbor.Comms.TestConversationSQLite
  alias Arbor.Comms.TestConversationSQLite.Repo
  alias Arbor.Persistence

  alias __MODULE__.{
    Backend,
    LostReceiptBackend,
    ContentionBackend,
    GapBackend,
    EmptyRangeBackend,
    UnavailableBackend,
    ExactUnavailableBackend,
    MismatchedAckBackend
  }

  @moduletag :integration
  @moduletag :sqlite
  @moduletag capture_log: true
  @scope %{principal_id: "human_test", agent_id: "agent_test", engagement_id: "eng_test"}
  @command %{id: "cmd_1", text: "hello 👋"}

  setup_all do
    for app <- [:ecto_sql, :ecto_sqlite3, :jason],
        do: {:ok, _} = Application.ensure_all_started(app)

    :ok
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "conversation-journal-#{System.pid()}-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}.sqlite3"
      )

    start_supervised!(
      {Repo, database: database, pool_size: 8, busy_timeout: 2_000, journal_mode: :wal}
    )

    TestConversationSQLite.create_schema!(Repo)
    previous = Application.get_env(:arbor_comms, :conversation_journal)
    TestConversationSQLite.configure()

    start_supervised!(%{
      id: :contention,
      start: {Agent, :start_link, [fn -> false end, [name: __MODULE__.Contention]]}
    })

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_comms, :conversation_journal),
        else: Application.put_env(:arbor_comms, :conversation_journal, previous)

      for path <- [database, database <> "-wal", database <> "-shm"], do: File.rm(path)
    end)

    :ok
  end

  test "concurrent equal retries retain one original admission, and claim has exactly one winner" do
    results = parallel(8, fn -> Journal.admit(@scope, @command) end)
    assert Enum.all?(results, &match?({:ok, %{status: :admitted}}, &1))
    assert length(Enum.uniq(results)) == 1
    claims = parallel(8, fn -> Journal.claim(@scope, @command.id) end)
    assert Enum.count(claims, &match?({:ok, _}, &1)) == 1
    assert Enum.count(claims, &(&1 == {:error, :already_claimed})) == 7
    assert {:ok, %{events: events, cursor: 2, head: 2}} = Journal.events(@scope, 0)
    assert length(events) == 2
    refute inspect(events) =~ "claim_token"
  end

  test "security regression: changed exact input or destination cannot reuse a saved identity" do
    assert {:ok, original} = Journal.admit(@scope, @command)
    assert {:ok, ^original} = Journal.admit(@scope, @command)
    assert {:error, :command_conflict} = Journal.admit(@scope, %{@command | text: "changed"})

    assert {:error, :command_conflict} =
             Journal.admit(%{@scope | engagement_id: "other"}, @command)

    assert {:error, :command_conflict} = Journal.admit(%{@scope | agent_id: "other"}, @command)
    assert {:error, :invalid_command} = Journal.admit(@scope, Map.put(@command, :name, "another"))

    assert {:ok, %{status: :admitted}} =
             Journal.admit(%{@scope | principal_id: "different"}, @command)
  end

  test "security regression: a private command binding requires the live winning claim and exact source scope/text" do
    assert {:ok, _} = Arbor.Comms.admit_conversation_command(@scope, @command)
    assert {:ok, token} = Arbor.Comms.claim_conversation_command(@scope, @command.id)

    assert {:ok, binding} =
             Arbor.Comms.bind_conversation_command_claim(@scope, @command.id, token)

    assert {:ok, %{command_id: "cmd_1", task_id: task_id}} =
             Arbor.Comms.validate_conversation_command_binding(binding, @scope, @command.text)

    assert String.starts_with?(task_id, "conversation_")

    for {candidate, scope, text} <- [
          {%{binding | claim_token: String.duplicate("0", 64)}, @scope, @command.text},
          {binding, %{@scope | principal_id: "human_other"}, @command.text},
          {binding, %{@scope | agent_id: "agent_other"}, @command.text},
          {binding, %{@scope | engagement_id: "eng_other"}, @command.text},
          {binding, @scope, @command.text <> " "},
          {binding, @scope, nil},
          {binding, @scope, 7},
          {binding, @scope, ""},
          {binding, @scope, " "},
          {binding, @scope, String.duplicate("a", 32_769)},
          {Map.put(binding, :task_id, "caller_task"), @scope, @command.text}
        ] do
      assert {:error, :invalid_claim} =
               Arbor.Comms.validate_conversation_command_binding(candidate, scope, text)
    end

    assert {:ok, _} =
             Arbor.Comms.settle_conversation_command(@scope, @command.id, token, %{
               status: :uncertain,
               reason: :delivery_unknown
             })

    assert {:error, :invalid_claim} =
             Arbor.Comms.validate_conversation_command_binding(binding, @scope, @command.text)

    assert {:ok, command} = Arbor.Comms.get_conversation_command(@scope, @command.id)
    refute Map.has_key?(command, :claim_token)
  end

  test "security regression: an empty projection range behind a factual source head cannot advance or spin" do
    assert {:ok, _} = Arbor.Comms.admit_conversation_command(@scope, @command)
    use_backend(EmptyRangeBackend)
    assert {:ok, 1} = Journal.source_head(@scope)
    assert {:error, :invalid_journal} = Journal.projection_page(@scope, 0)
    assert {:ok, %{rows: [], from: 1, to: 1, head: 1}} = Journal.projection_page(@scope, 1)
  end

  test "lost append receipt is reconciled before issuing a claim" do
    use_backend(LostReceiptBackend)
    assert {:ok, %{status: :admitted}} = Journal.admit(@scope, @command)
    assert {:ok, token} = Journal.claim(@scope, @command.id)
    assert {:error, :already_claimed} = Journal.claim(@scope, @command.id)

    assert {:ok, %{status: :completed}} =
             Journal.settle(@scope, @command.id, token, %{status: :completed, text: "reply"})

    assert {:ok, %{cursor: 3}} = Journal.events(@scope, 0)
  end

  test "unrelated stream-head contention builds a fresh append operation after a fenced failure" do
    use_backend(ContentionBackend)
    assert {:ok, %{admitted_cursor: 2}} = Journal.admit(@scope, @command)
    assert {:ok, %{head: 2, events: [first, second]}} = Journal.events(@scope, 0)
    assert first.command.id == "competing"
    assert second.command.id == @command.id

    assert Repo.query!("SELECT COUNT(*) FROM event_log_operations WHERE status = 'aborted'").rows ==
             [[1]]
  end

  test "security regression: a mismatched committed claim acknowledgement grants no token" do
    assert {:ok, _} = Journal.admit(@scope, @command)
    use_backend(MismatchedAckBackend)
    assert {:error, :invalid_journal_acknowledgement} = Journal.claim(@scope, @command.id)
    use_backend(Arbor.Persistence.EventLog.Ecto)
    assert {:ok, %{status: :dispatch_started}} = Journal.get(@scope, @command.id)
    assert {:error, :already_claimed} = Journal.claim(@scope, @command.id)
  end

  test "a killed claiming process leaves factual unresolved dispatch and cannot be redispatched" do
    assert {:ok, _} = Journal.admit(@scope, @command)
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:claimed, Journal.claim(@scope, @command.id)})

        receive do
          :never -> :ok
        end
      end)

    monitor = Process.monitor(pid)
    assert_receive {:claimed, {:ok, _token}}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, %{status: :dispatch_started, outcome: nil}} = Journal.get(@scope, @command.id)
    assert {:error, :already_claimed} = Journal.claim(@scope, @command.id)
  end

  test "one terminal result is durable and a late different result cannot replace it" do
    {:ok, _} = Journal.admit(@scope, @command)
    {:ok, token} = Journal.claim(@scope, @command.id)
    outcome = %{status: :uncertain, reason: :delivery_unknown}
    assert {:ok, terminal} = Journal.settle(@scope, @command.id, token, outcome)
    assert {:ok, ^terminal} = Journal.settle(@scope, @command.id, token, outcome)

    assert {:error, :terminal_conflict} =
             Journal.settle(@scope, @command.id, token, %{status: :completed, text: "late"})

    assert {:error, :invalid_claim} =
             Journal.settle(@scope, @command.id, String.duplicate("b", 64), outcome)

    assert {:ok, %{head: 3}} = Journal.events(@scope, 0)
  end

  test "a pinned cursor converges while later writes stay outside that prefix" do
    {:ok, _} = Journal.admit(@scope, @command)
    {:ok, token} = Journal.claim(@scope, @command.id)
    assert {:ok, %{cursor: 1, head: 2, has_more: true}} = Journal.events(@scope, 0, limit: 1)
    {:ok, _} = Journal.settle(@scope, @command.id, token, %{status: :completed, text: "reply"})
    assert {:ok, %{cursor: 2, head: 2, has_more: false}} = Journal.events(@scope, 1, through: 2)
    assert {:ok, %{cursor: 3, head: 3, has_more: false}} = Journal.events(@scope, 2)
    assert {:error, :invalid_cursor} = Journal.events(@scope, 4)
    assert {:error, :invalid_cursor} = Journal.events(@scope, 0, through: 100)
  end

  test "storage failures, gaps and unknown authoritative records never yield a successful checkpoint" do
    {:ok, _} = Journal.admit(@scope, @command)
    use_backend(GapBackend)
    assert {:error, :invalid_journal} = Journal.events(@scope, 0)
    use_backend(UnavailableBackend)
    assert {:error, :offline} = Journal.events(@scope, 0)
    use_backend(ExactUnavailableBackend)

    assert {:error, :invalid_journal} =
             Arbor.Comms.admit_conversation_command(@scope, %{id: "source_offline", text: "x"})

    use_backend(Arbor.Persistence.EventLog.ETS)
    assert {:error, :journal_not_durable} = Journal.admit(@scope, %{id: "volatile", text: "x"})
    use_backend(Arbor.Persistence.EventLog.Ecto)

    unknown =
      Persistence.new_event(Core.stream_id(@scope), "unknown.authoritative", %{},
        id: "unknown",
        agent_id: @scope.agent_id,
        metadata: %{"attempt_id" => String.duplicate("a", 64)}
      )

    assert {:ok, [_]} =
             Persistence.append(
               :test,
               Arbor.Persistence.EventLog.Ecto,
               Core.stream_id(@scope),
               unknown,
               repo: Repo
             )

    assert {:error, :invalid_journal} = Journal.events(@scope, 0)
    assert {:error, :invalid_journal} = Arbor.Comms.get_conversation_command(@scope, @command.id)

    assert {:error, :invalid_journal} =
             Arbor.Comms.claim_conversation_command(@scope, @command.id)
  end

  test "security regression: durable cancellation before claim survives reconstruction and never grants dispatch" do
    assert {:ok, _} = Arbor.Comms.admit_conversation_command(@scope, @command)

    assert {:ok,
            %{
              status: :admitted,
              cancellation: %{status: :confirmed, termination: :never_dispatched}
            } = original} =
             Arbor.Comms.request_conversation_command_cancellation(@scope, @command.id)

    assert {:ok, ^original} =
             Arbor.Comms.request_conversation_command_cancellation(@scope, @command.id)

    assert {:error, :already_claimed} =
             Arbor.Comms.claim_conversation_command(@scope, @command.id)

    assert {:ok, ^original} = Arbor.Comms.get_conversation_command(@scope, @command.id)
    assert {:ok, %{events: events, head: 3}} = Arbor.Comms.conversation_events(@scope, 0)
    assert Enum.map(events, & &1.kind) == ["admitted", "cancel_requested", "cancel_acknowledged"]

    assert {:error, :not_found} =
             Arbor.Comms.request_conversation_command_cancellation(@scope, "missing")
  end

  test "security regression: cancellation intent invalidates exact claim and cannot rewrite terminal delivery" do
    for status <- [:completed, :uncertain] do
      command = %{@command | id: "terminal-#{status}"}
      assert {:ok, _} = Arbor.Comms.admit_conversation_command(@scope, command)
      assert {:ok, token} = Arbor.Comms.claim_conversation_command(@scope, command.id)

      assert {:ok, binding} =
               Arbor.Comms.bind_conversation_command_claim(@scope, command.id, token)

      assert {:ok, %{cancellation: %{status: :requested}}} =
               Arbor.Comms.request_conversation_command_cancellation(@scope, command.id)

      assert {:error, :invalid_claim} =
               Arbor.Comms.validate_conversation_command_binding(binding, @scope, command.text)

      outcome =
        if status == :completed,
          do: %{status: :completed, text: "immutable"},
          else: %{status: :uncertain, reason: :delivery_unknown}

      assert {:ok, _} =
               Arbor.Comms.settle_conversation_command(@scope, command.id, token, outcome)

      assert {:ok,
              %{
                status: ^status,
                outcome: ^outcome,
                cancellation: %{status: :confirmed, termination: :engine_terminated}
              }} =
               Arbor.Comms.acknowledge_conversation_command_cancellation(
                 binding,
                 :engine_terminated
               )

      assert {:error, :invalid_cancellation} =
               Arbor.Comms.acknowledge_conversation_command_cancellation(
                 binding,
                 :never_dispatched
               )
    end
  end

  defp parallel(count, fun) do
    1..count
    |> Task.async_stream(fn _ -> fun.() end, max_concurrency: count, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp use_backend(backend) do
    Application.put_env(:arbor_comms, :conversation_journal,
      name: :conversation_journal_test,
      backend: backend,
      opts: [repo: Repo, timeout_ms: 5_000]
    )
  end

  defmodule Backend do
    alias Arbor.Persistence.EventLog.Ecto, as: EctoBackend

    def durability_class(_), do: :node_restart

    def append(stream, events, opts),
      do: EctoBackend.append(stream, events, opts)

    def reconcile_append(operation, opts),
      do: EctoBackend.reconcile_append(operation, opts)

    def read_stream_head(stream, opts),
      do: EctoBackend.read_stream_head(stream, opts)

    def read_stream_range(stream, opts),
      do: EctoBackend.read_stream_range(stream, opts)

    def read_event_records(stream, ids, opts),
      do: EctoBackend.read_event_records(stream, ids, opts)
  end

  defmodule LostReceiptBackend do
    alias Arbor.Persistence.EventLog

    defdelegate durability_class(opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_head(stream, opts), to: Backend
    defdelegate read_stream_range(stream, opts), to: Backend
    defdelegate read_event_records(stream, ids, opts), to: Backend

    def append(stream, events, opts) do
      with {:ok, _} <- Backend.append(stream, events, opts),
           {:ok, operation} <- EventLog.build_operation(stream, events) do
        {:error, {:append_indeterminate, operation}}
      end
    end
  end

  defmodule ContentionBackend do
    defdelegate durability_class(opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_head(stream, opts), to: Backend
    defdelegate read_stream_range(stream, opts), to: Backend
    defdelegate read_event_records(stream, ids, opts), to: Backend

    def append(stream, [event] = events, opts) do
      if Agent.get_and_update(Arbor.Comms.ConversationJournalTest.Contention, &{not &1, true}) do
        scope = %{
          principal_id: event.data["principal_id"],
          agent_id: event.data["agent_id"],
          engagement_id: event.data["engagement_id"]
        }

        other = %{
          event
          | id: Core.event_id(scope, "competing", "admitted"),
            data: Map.put(event.data, "command_id", "competing")
        }

        {:ok, [_]} = Backend.append(stream, [other], opts)
      end

      Backend.append(stream, events, opts)
    end
  end

  defmodule GapBackend do
    defdelegate read_event_records(stream, ids, opts), to: Backend
    defdelegate durability_class(opts), to: Backend
    defdelegate append(stream, events, opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_head(stream, opts), to: Backend

    def read_stream_range(stream, opts) do
      with {:ok, events} <- Backend.read_stream_range(stream, opts),
           do: {:ok, Enum.drop(events, 1)}
    end
  end

  defmodule EmptyRangeBackend do
    defdelegate durability_class(opts), to: Backend
    defdelegate append(stream, events, opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_head(stream, opts), to: Backend
    defdelegate read_event_records(stream, ids, opts), to: Backend
    def read_stream_range(_, _), do: {:ok, []}
  end

  defmodule MismatchedAckBackend do
    defdelegate durability_class(opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_head(stream, opts), to: Backend
    defdelegate read_stream_range(stream, opts), to: Backend
    defdelegate read_event_records(stream, ids, opts), to: Backend

    def append(stream, events, opts) do
      with {:ok, [event]} <- Backend.append(stream, events, opts) do
        {:ok, [%{event | data: Map.put(event.data, "token", String.duplicate("0", 64))}]}
      end
    end
  end

  defmodule UnavailableBackend do
    defdelegate durability_class(opts), to: Backend
    defdelegate append(stream, events, opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_range(stream, opts), to: Backend
    defdelegate read_event_records(stream, ids, opts), to: Backend
    def read_stream_head(_, _), do: {:error, :offline}
  end

  defmodule ExactUnavailableBackend do
    defdelegate durability_class(opts), to: Backend
    defdelegate append(stream, events, opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_head(stream, opts), to: Backend
    defdelegate read_stream_range(stream, opts), to: Backend
    def event_identity(_, _, _), do: {:ok, nil}
    def read_event_records(_, _, _), do: {:error, :backend_unavailable}
  end
end
