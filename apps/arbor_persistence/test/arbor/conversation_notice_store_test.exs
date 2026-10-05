defmodule Arbor.Persistence.ConversationNoticeStoreTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Arbor.Persistence

  alias Arbor.Persistence.Schemas.{
    Engagement,
    ConversationNotice,
    ConversationNoticeHead,
    Session,
    SessionEntry
  }

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @moduletag :database
  @moduletag :isolated_repo
  @moduletag :fast

  defmodule IsolatedRepo do
    use Ecto.Repo, otp_app: :arbor_persistence, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "conversation_notice_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    opts = [
      database: Path.join(root, "notices.db"),
      pool_size: 2,
      journal_mode: :wal,
      busy_timeout: 5_000,
      default_transaction_mode: :immediate
    ]

    previous = Application.get_env(:arbor_persistence, :sql_repository)
    Application.put_env(:arbor_persistence, :sql_repository, IsolatedRepo)
    start_supervised!({IsolatedRepo, Keyword.put(opts, :pool_size, 1)})

    for {filename, version, module} <- [
          {"20260222100001_create_sessions_and_channels.exs", 20_260_222_100_001,
           Arbor.Persistence.Repo.Migrations.CreateSessionsAndChannels},
          {"20260622150001_create_engagements.exs", 20_260_622_150_001,
           Arbor.Persistence.Repo.Migrations.CreateEngagements},
          {"20261003000002_create_conversation_notices.exs", 20_261_003_000_002,
           Arbor.Persistence.Repo.Migrations.CreateConversationNotices}
        ] do
      Code.require_file(Path.expand("../../priv/repo/migrations/#{filename}", __DIR__))
      :ok = Ecto.Migrator.up(IsolatedRepo, version, module, log: false)
    end

    :ok = stop_supervised(IsolatedRepo)
    start_supervised!({IsolatedRepo, opts})
    Arbor.Persistence.Repo.put_dynamic_repo(IsolatedRepo)
    scope = scope(1)
    put_engagement(scope)
    warm_repository()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbor_persistence, :sql_repository, previous),
        else: Application.delete_env(:arbor_persistence, :sql_repository)

      File.rm_rf!(root)
    end)

    {:ok, scope: scope, opts: opts}
  end

  test "public append assigns durable ordinal/time and atomically adds Home activity without transcript rows",
       %{scope: scope} do
    value = value(scope, 1, "private native progress", "progress")
    before = DateTime.utc_now()

    assert {:ok, %{disposition: :inserted, notice: saved}} =
             Persistence.append_conversation_notice(scope, value)

    assert saved.ordinal == 1
    assert {:ok, created, 0} = DateTime.from_iso8601(saved.created_at)
    assert DateTime.compare(created, before) in [:eq, :gt]
    assert IsolatedRepo.aggregate(Session, :count) == 0
    assert IsolatedRepo.aggregate(SessionEntry, :count) == 0
    assert IsolatedRepo.one(from(e in Engagement, select: e.updated_at)) == created
    assert IsolatedRepo.get!(ConversationNoticeHead, scope.engagement_id).activity_at == created

    assert {:ok, %{records: [record]}} =
             Persistence.list_user_conversation_records(scope.owner_id)

    assert record.updated_at == created

    assert {:ok,
            %{
              notices: [public],
              head: 1,
              through: 1,
              complete: true,
              has_older: false,
              next_before: nil
            } = page} = Persistence.read_conversation_notice_page(scope)

    assert public.text == value.text

    assert Enum.sort(Map.keys(public)) ==
             Enum.sort([
               :notice_id,
               :recipient_subject_id,
               :kind,
               :text,
               :provenance,
               :ordinal,
               :created_at
             ])

    assert public.recipient_subject_id == value.recipient_subject_id
    refute Map.has_key?(public, :facts_digest)
    refute Jason.encode!(page) =~ "facts_digest"
  end

  test "native security regression: valid immutable facts cannot append without private worker admission",
       %{scope: scope} do
    notice = value(scope, 1, "a validation hash is not publisher authority")

    original_activity =
      IsolatedRepo.get_by!(Engagement, engagement_id: scope.engagement_id).updated_at

    {:ok, _} = Application.ensure_all_started(:arbor_security)
    assert :ok = Arbor.Security.TestBootstrap.start!()

    assert {:error, :native_notice_source_required} =
             Persistence.append_native_conversation_notice(scope, notice)

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 0
    assert IsolatedRepo.aggregate(ConversationNoticeHead, :count) == 0

    assert IsolatedRepo.get_by!(Engagement, engagement_id: scope.engagement_id).updated_at ==
             original_activity

    assert {:ok, %{notices: [], head: 0, through: 0}} =
             Persistence.read_conversation_notice_page(scope)

    assert {:error, :notice_not_found} =
             Persistence.reconcile_conversation_notice(scope, notice)

    assert IsolatedRepo.aggregate(Session, :count) == 0
    assert IsolatedRepo.aggregate(SessionEntry, :count) == 0
  end

  test "native security regression: existing exact storage facts cannot bypass fresh worker admission",
       %{scope: scope} do
    notice = value(scope, 1, "historical storage evidence is not a fresh source lease")
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    assert :ok = Arbor.Security.TestBootstrap.start!()

    assert {:ok, %{disposition: :inserted, notice: saved}} =
             Persistence.append_conversation_notice(scope, notice)

    assert {:error, :native_notice_source_required} =
             Persistence.append_native_conversation_notice(scope, notice)

    assert {:ok, %{disposition: :existing, notice: ^saved}} =
             Persistence.reconcile_conversation_notice(scope, notice)

    assert {:ok, %{notices: [^saved], head: 1, through: 1}} =
             Persistence.read_conversation_notice_page(scope)

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1
    {:ok, created_at, 0} = DateTime.from_iso8601(saved.created_at)

    assert IsolatedRepo.get_by!(Engagement, engagement_id: scope.engagement_id).updated_at ==
             created_at

    assert IsolatedRepo.get!(ConversationNoticeHead, scope.engagement_id).activity_at ==
             created_at

    assert IsolatedRepo.aggregate(Session, :count) == 0
    assert IsolatedRepo.aggregate(SessionEntry, :count) == 0
  end

  test "same ID and immutable caller facts append once and changed facts conflict", %{
    scope: scope
  } do
    first = value(scope, 1)

    assert {:ok, %{notice: saved, disposition: :inserted}} =
             Persistence.append_conversation_notice(scope, first)

    assert {:ok, %{notice: ^saved, disposition: :existing}} =
             Persistence.append_conversation_notice(scope, first)

    assert {:error, :notice_conflict} =
             Persistence.append_conversation_notice(scope, value(scope, 1, "changed"))

    changed_subject = value(scope, 1, "notice1", "notification", "human_other_subject")

    assert {:error, :notice_conflict} =
             Persistence.append_conversation_notice(scope, changed_subject)

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1
    assert IsolatedRepo.get!(ConversationNoticeHead, scope.engagement_id).ordinal == 1

    assert IsolatedRepo.get!(ConversationNoticeHead, scope.engagement_id).activity_at
           |> DateTime.to_iso8601() == saved.created_at
  end

  test "security regression exact existing owner agent private user scope precedes reads and writes",
       %{scope: own} do
    assert {:ok, _} = Persistence.append_conversation_notice(own, value(own, 1))

    for scope <- [
          Map.put(own, :owner_id, "human_foreign"),
          Map.put(own, :target_agent_id, "agent_foreign"),
          scope(2)
        ] do
      assert {:error, :notice_scope_not_found} =
               Persistence.append_conversation_notice(scope, value(scope, 2))

      assert {:error, :notice_scope_not_found} =
               Persistence.reconcile_conversation_notice(scope, value(scope, 2))

      assert {:error, :notice_scope_not_found} = Persistence.read_conversation_notice_page(scope)
    end

    for {field, invalid} <- [{:scope, "channel"}, {:visibility, "group"}] do
      IsolatedRepo.update_all(Engagement, set: [{field, invalid}])
      assert {:error, :notice_scope_not_found} = Persistence.read_conversation_notice_page(own)

      assert {:error, :notice_scope_not_found} =
               Persistence.append_conversation_notice(own, value(own, 2))

      IsolatedRepo.update_all(Engagement,
        set: [{field, if(field == :scope, do: "user", else: "private")}]
      )
    end

    assert IsolatedRepo.aggregate(Engagement, :count) == 1
    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1
  end

  test "security regression closed facts reject forged provenance and caller timestamps before SQL",
       %{scope: scope} do
    good = value(scope, 1)

    for bad <- [
          Map.put(good, :created_at, "fake"),
          Map.put(good, :ordinal, 7),
          Map.put(good, "text", "duplicate"),
          Map.put(good, :text, "unbound"),
          put_in(good, [:provenance, "taint", "taint", "level"], "trusted"),
          Map.put(good, :recipient_subject_id, "human_unbound")
        ] do
      assert {:error, :invalid_notice} = Persistence.append_conversation_notice(scope, bad)
    end

    assert {:error, :invalid_notice_scope} =
             Persistence.append_conversation_notice(Map.put(scope, :proof, "forged"), good)

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 0
    assert IsolatedRepo.aggregate(ConversationNoticeHead, :count) == 0
  end

  test "SQL failure after notice insert rolls back notice head and engagement activity together",
       %{scope: scope} do
    original = IsolatedRepo.one(from(e in Engagement, select: e.updated_at))

    IsolatedRepo.query!(
      "CREATE TRIGGER refuse_notice_head BEFORE INSERT ON conversation_notice_heads BEGIN SELECT RAISE(ABORT, 'fixture head refused'); END"
    )

    assert {:error, :notice_unavailable} =
             Persistence.append_conversation_notice(scope, value(scope, 1))

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 0
    assert IsolatedRepo.aggregate(ConversationNoticeHead, :count) == 0
    assert IsolatedRepo.one(from(e in Engagement, select: e.updated_at)) == original

    assert {:error, :notice_not_found} =
             Persistence.reconcile_conversation_notice(scope, value(scope, 1))

    IsolatedRepo.query!("DROP TRIGGER refuse_notice_head")

    assert {:ok, %{notice: %{ordinal: 1}, disposition: :inserted}} =
             Persistence.append_conversation_notice(scope, value(scope, 1))
  end

  test "hostile restricted source provenance is stored and projected without promotion", %{
    scope: scope
  } do
    ordinary = value(scope, 1)

    elevated =
      ordinary
      |> put_in([:provenance, "taint", "taint", "level"], "hostile")
      |> put_in([:provenance, "taint", "taint", "sensitivity"], "restricted")

    assert {:ok, _} = Persistence.append_conversation_notice(scope, elevated)

    assert {:ok, %{notices: [%{provenance: provenance}]}} =
             Persistence.read_conversation_notice_page(scope)

    assert provenance == elevated.provenance
    assert get_in(provenance, ["taint", "taint", "level"]) == "hostile"
    assert get_in(provenance, ["taint", "taint", "sensitivity"]) == "restricted"
  end

  test "lost successful reply reconciles exact facts without reappend or a new timestamp", %{
    scope: scope
  } do
    expected = value(scope, 1)

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, _discarded_reply} = Persistence.append_conversation_notice(scope, expected)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert {:ok, %{disposition: :existing, notice: saved}} =
             Persistence.reconcile_conversation_notice(scope, expected)

    assert saved.ordinal == 1

    assert {:error, :notice_conflict} =
             Persistence.reconcile_conversation_notice(scope, value(scope, 1, "different"))

    assert {:error, :notice_not_found} =
             Persistence.reconcile_conversation_notice(scope, value(scope, 2))

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1
  end

  test "notice identity first timestamp and head survive actual repository reopen", %{
    scope: scope,
    opts: opts
  } do
    expected = value(scope, 1)
    assert {:ok, %{notice: saved}} = Persistence.append_conversation_notice(scope, expected)
    :ok = stop_supervised(IsolatedRepo)
    start_supervised!({IsolatedRepo, opts})

    warm_repository()
    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1

    assert {:ok, %{disposition: :existing, notice: ^saved}} =
             Persistence.reconcile_conversation_notice(scope, expected)

    assert {:ok, %{notice: %{ordinal: 2}}} =
             Persistence.append_conversation_notice(scope, value(scope, 2))

    assert {:ok, %{notices: [second, first], head: 2}} =
             Persistence.read_conversation_notice_page(scope)

    assert first.ordinal == 1
    assert second.ordinal == 2
  end

  test "strict older paging is scope filtered sparse and pinned against interleaved appends", %{
    scope: scope
  } do
    other = scope(2)
    put_engagement(other)

    for n <- 1..55 do
      assert {:ok, _} = Persistence.append_conversation_notice(scope, value(scope, n))

      if rem(n, 10) == 0,
        do: assert({:ok, _} = Persistence.append_conversation_notice(other, value(other, n)))
    end

    IsolatedRepo.delete_all(
      from(n in ConversationNotice,
        where: n.engagement_id == ^scope.engagement_id and n.ordinal in [10, 28]
      )
    )

    assert {:ok, %{notices: first, head: 55, through: 55, has_older: true, next_before: 36}} =
             Persistence.read_conversation_notice_page(scope)

    assert Enum.map(first, & &1.ordinal) == Enum.to_list(55..36//-1)
    assert {:ok, _} = Persistence.append_conversation_notice(scope, value(scope, 56))

    assert {:ok, %{head: 56, through: 55} = second} =
             Persistence.read_conversation_notice_page(scope, before: 36, through: 55, limit: 50)

    assert Enum.map(second.notices, & &1.ordinal) ==
             Enum.reject(Enum.to_list(35..1//-1), &(&1 in [10, 28]))

    refute second.has_older
    assert second.next_before == nil

    assert {:ok, %{notices: [%{ordinal: 56} | _]}} =
             Persistence.read_conversation_notice_page(scope, limit: 50)

    assert {:ok, %{notices: [], head: 56, through: 55, has_older: false}} =
             Persistence.read_conversation_notice_page(scope, before: 1, through: 55)
  end

  test "concurrent admissions serialize exact scoped ordinals and duplicate identities", %{
    scope: scope
  } do
    values = Enum.map(1..12, &value(scope, &1))

    results =
      Task.async_stream(
        values ++ Enum.take(values, 4),
        fn expected ->
          Persistence.append_conversation_notice(scope, expected)
        end,
        max_concurrency: 4,
        ordered: false,
        timeout: 5_500
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert Enum.count(results, &match?({:ok, {:ok, %{disposition: :inserted}}}, &1)) == 12
    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 12
    assert {:ok, %{notices: notices, head: 12}} = Persistence.read_conversation_notice_page(scope)
    assert Enum.map(notices, & &1.ordinal) == Enum.to_list(12..1//-1)

    assert Enum.sort(Enum.map(notices, & &1.notice_id)) ==
             Enum.sort(Enum.map(values, & &1.notice_id))
  end

  test "byte packing keeps full maximum text with exact continuation and no skipped notice", %{
    scope: scope
  } do
    text = String.duplicate("é", 16_384)

    for n <- 1..6,
        do:
          assert({:ok, _} = Persistence.append_conversation_notice(scope, value(scope, n, text)))

    assert {:ok, first} = Persistence.read_conversation_notice_page(scope, limit: 50)
    assert byte_size(Jason.encode!(first)) <= 129_024
    assert length(first.notices) == 3
    assert first.next_before == 4
    assert first.has_older
    assert Enum.all?(first.notices, &(&1.text == text))

    assert {:ok, second} =
             Persistence.read_conversation_notice_page(scope,
               limit: 50,
               through: first.through,
               before: first.next_before
             )

    assert Enum.map(first.notices ++ second.notices, & &1.ordinal) == [6, 5, 4, 3, 2, 1]
    assert Enum.all?(second.notices, &(&1.text == text))
    refute second.has_older
  end

  test "maximum identifier metadata and escaped full text still guarantee first-record page progress" do
    scope = %{
      scope(2)
      | owner_id: "human_" <> String.duplicate("x", 250),
        target_agent_id: "agent_" <> String.duplicate("y", 250)
    }

    subject = "human_" <> String.duplicate("z", 250)
    put_engagement(scope)
    text = String.duplicate(<<0>>, 17_000) <> String.duplicate("q", 15_768)

    for n <- 1..2,
        do:
          assert(
            {:ok, _} =
              Persistence.append_conversation_notice(
                scope,
                value(scope, n, text, "progress", subject)
              )
          )

    assert {:ok, %{notices: [record], head: 2, next_before: 2, has_older: true} = page} =
             Persistence.read_conversation_notice_page(scope, limit: 50)

    assert record.text == text
    assert record.recipient_subject_id == subject
    assert byte_size(Jason.encode!(page)) <= 129_024

    assert {:ok, %{notices: [%{ordinal: 1, text: ^text}], has_older: false}} =
             Persistence.read_conversation_notice_page(scope, before: 2, through: 2)
  end

  test "encoded oversized single notice is refused without stranding page progress", %{
    scope: scope
  } do
    oversized = value(scope, 1, String.duplicate(<<0>>, 32_767) <> "x")
    assert {:error, reason} = Persistence.append_conversation_notice(scope, oversized)
    assert reason in [:invalid_notice, :notice_too_large]
    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 0

    assert {:ok, %{notices: [], head: 0, through: 0, has_older: false, complete: true}} =
             Persistence.read_conversation_notice_page(scope)

    assert {:ok, _} = Persistence.append_conversation_notice(scope, value(scope, 2))
  end

  test "security regression corrupt private subject bound provenance refuses stored disclosure",
       %{scope: scope} do
    assert {:ok, _} = Persistence.append_conversation_notice(scope, value(scope, 1))
    IsolatedRepo.update_all(ConversationNotice, set: [recipient_subject_id: "human_forged"])
    assert {:error, :invalid_notice_record} = Persistence.read_conversation_notice_page(scope)
  end

  test "held SQLite writer does not block scoped read or cause a late notice/Home mutation", %{
    scope: scope
  } do
    assert {:ok, %{notice: first}} =
             Persistence.append_conversation_notice(scope, value(scope, 1))

    parent = self()

    task =
      Task.async(fn ->
        IsolatedRepo.transaction(
          fn ->
            IsolatedRepo.query!("UPDATE engagements SET status = status")
            send(parent, :writer_held)

            receive do
              :release_writer -> :ok
            end
          end,
          timeout: 10_000
        )
      end)

    assert_receive :writer_held
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{notices: [_], head: 1}} = Persistence.read_conversation_notice_page(scope)

    assert {:error, :notice_unavailable} =
             Persistence.append_conversation_notice(scope, value(scope, 2))

    assert (System.monotonic_time(:millisecond) - started) in 4_800..5_500

    assert {:error, pending_read} =
             Persistence.reconcile_conversation_notice(scope, value(scope, 2))

    # SQLite may discard the failed BEGIN connection. Unavailability is not an
    # absence claim, and no append is retried from it.
    assert pending_read in [:notice_not_found, :notice_unavailable]

    send(task.pid, :release_writer)
    assert {:ok, :ok} = Task.await(task)
    warm_repository()

    assert {:error, :notice_not_found} =
             Persistence.reconcile_conversation_notice(scope, value(scope, 2))

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1

    assert IsolatedRepo.get!(ConversationNoticeHead, scope.engagement_id).activity_at
           |> DateTime.to_iso8601() == first.created_at

    assert {:ok, %{notice: %{ordinal: 2}}} =
             Persistence.append_conversation_notice(scope, value(scope, 2))

    assert %{rows: [[5_000]]} = IsolatedRepo.query!("PRAGMA busy_timeout")
  end

  test "one admission safely acquires a promptly released writer before its first effect", %{
    scope: scope
  } do
    parent = self()

    holder =
      Task.async(fn ->
        IsolatedRepo.transaction(fn ->
          IsolatedRepo.query!("UPDATE engagements SET status = status")
          send(parent, :prompt_writer_held)

          receive do
            :release_prompt_writer -> :ok
          end
        end)
      end)

    assert_receive :prompt_writer_held
    append = Task.async(fn -> Persistence.append_conversation_notice(scope, value(scope, 1)) end)
    refute Task.yield(append, 75)
    send(holder.pid, :release_prompt_writer)
    assert {:ok, :ok} = Task.await(holder)
    assert {:ok, %{disposition: :inserted, notice: %{ordinal: 1}}} = Task.await(append)
    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1
    assert IsolatedRepo.get!(ConversationNoticeHead, scope.engagement_id).ordinal == 1
  end

  test "directory activity notices dominate older transcript and stay exactly scoped", %{
    scope: scope
  } do
    other = scope(2)
    put_engagement(other)

    session =
      IsolatedRepo.insert!(%Session{
        session_id: "agent-session-" <> scope.target_agent_id,
        agent_id: scope.target_agent_id
      })

    IsolatedRepo.insert!(%SessionEntry{
      session_id: session.id,
      entry_type: "user",
      content: [],
      timestamp: ~U[2020-01-01 00:00:00.000000Z],
      metadata: %{"engagement_id" => scope.engagement_id}
    })

    assert {:ok, %{notice: saved}} =
             Persistence.append_conversation_notice(scope, value(scope, 1))

    assert {:ok, %{records: [record]}} =
             Persistence.list_user_conversation_records(scope.owner_id, limit: 1)

    assert record.engagement_id == scope.engagement_id
    assert DateTime.to_iso8601(record.updated_at) == saved.created_at
    assert IsolatedRepo.aggregate(SessionEntry, :count) == 1
  end

  test "closed pagination grammar and stored head integrity refuse ambiguous boundaries", %{
    scope: scope
  } do
    for opts <- [
          [limit: 0],
          [limit: 51],
          [before: 0],
          [before: 1.0],
          [through: 0],
          [through: 1],
          [limit: 2, limit: 1],
          [proof: "forged"],
          %{}
        ] do
      assert {:error, :invalid_notice_options} =
               Persistence.read_conversation_notice_page(scope, opts)
    end

    assert {:ok, _} = Persistence.append_conversation_notice(scope, value(scope, 1))
    IsolatedRepo.update_all(ConversationNoticeHead, set: [owner_id: "human_forged"])
    assert {:error, :invalid_notice_record} = Persistence.read_conversation_notice_page(scope)
  end

  test "notice read acquisition regression: a promptly released real SQL pool returns the exact scoped page",
       %{
         scope: scope
       } do
    assert {:ok, %{notice: saved}} =
             Persistence.append_conversation_notice(scope, value(scope, 1, "pool-held notice"))

    with_notice_checkout_observer(fn ->
      with_held_notice_pool(fn holders ->
        reader = Task.async(fn -> Persistence.read_conversation_notice_page(scope) end)
        reader_pid = reader.pid

        try do
          # The documented event runs on the caller that actually attempted
          # checkout. Do not release the pool merely because time elapsed.
          assert_receive {:notice_checkout_refused, ^reader_pid, false, deadline}, 1_000
          assert is_integer(deadline)
          Enum.each(holders, &send(&1.pid, :release_notice_pool))

          assert {:ok, %{head: 1, through: 1, complete: true, notices: [notice]}} =
                   Task.await(reader, 2_000)

          assert notice == saved
          assert notice.text == "pool-held notice"
        after
          Enum.each(holders, &send(&1.pid, :release_notice_pool))
          reap_notice_tasks([reader])
        end
      end)
    end)

    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1
    assert IsolatedRepo.get!(ConversationNoticeHead, scope.engagement_id).ordinal == 1
  end

  @tag :slow
  @tag fast: false
  test "notice read pool exhaustion retains the original deadline and never becomes a late read",
       %{
         scope: scope
       } do
    assert {:ok, _} = Persistence.append_conversation_notice(scope, value(scope, 1))

    with_held_notice_pool(fn _holders ->
      started = System.monotonic_time(:millisecond)
      assert {:error, :notice_unavailable} = Persistence.read_conversation_notice_page(scope)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 5_750
    end)

    assert {:ok, %{head: 1, notices: [_]}} = Persistence.read_conversation_notice_page(scope)
    assert IsolatedRepo.aggregate(ConversationNotice, :count) == 1
  end

  test "notice read security regression: malformed scope fails before an exhausted SQL checkout" do
    with_held_notice_pool(fn _holders ->
      started = System.monotonic_time(:millisecond)

      for scope <- [
            %{},
            nil,
            %{owner_id: "human_notice_owner"},
            Map.put(scope(1), :proof, "forged")
          ] do
        assert {:error, :invalid_notice_scope} = Persistence.read_conversation_notice_page(scope)
      end

      assert System.monotonic_time(:millisecond) - started < 1_000
    end)
  end

  test "notice read refuses a stopped real repository without retrying unrelated failures", %{
    scope: scope
  } do
    :ok = stop_supervised(IsolatedRepo)
    started = System.monotonic_time(:millisecond)
    assert {:error, :notice_unavailable} = Persistence.read_conversation_notice_page(scope)
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  defp with_held_notice_pool(fun) do
    parent = self()

    holders =
      for _ <- 1..2 do
        Task.async(fn ->
          IsolatedRepo.checkout(fn ->
            send(parent, {:notice_pool_held, self()})

            receive do
              :release_notice_pool -> :ok
            after
              8_000 -> :notice_pool_holder_timeout
            end
          end)
        end)
      end

    try do
      Enum.each(holders, fn holder ->
        pid = holder.pid
        assert_receive {:notice_pool_held, ^pid}, 1_000
      end)

      fun.(holders)
    after
      Enum.each(holders, &send(&1.pid, :release_notice_pool))
      reap_notice_tasks(holders, :ok)
    end
  end

  defp reap_notice_tasks(tasks, expected \\ :any) do
    # Reap every owned task before asserting so one failed holder cannot
    # prevent cleanup of another. Forced cleanup is an explicit test failure.
    ready = Task.yield_many(tasks, 0)
    pending = for {task, nil} <- ready, expected != :any or Process.alive?(task.pid), do: task

    later =
      pending |> Task.yield_many(2_000) |> Map.new(fn {task, result} -> {task.ref, result} end)

    outcomes =
      ready
      |> Enum.map(fn {task, result} -> {task, result || Map.get(later, task.ref)} end)
      |> Enum.map(fn
        {_task, {:ok, result}} ->
          if expected == :any or result == expected,
            do: :normal,
            else: {:unexpected_result, result}

        {task, nil} ->
          if Process.alive?(task.pid) do
            Task.shutdown(task, :brutal_kill)
            :cleanup_timeout
          else
            if expected == :any, do: :already_reaped, else: :cleanup_result_unconfirmed
          end

        {_task, {:exit, reason}} ->
          {:cleanup_exit, reason}
      end)

    assert Enum.all?(outcomes, &(&1 in [:normal, :already_reaped]))
  end

  defp with_notice_checkout_observer(fun) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:db_connection, :connection_error],
        &__MODULE__.notice_checkout_error/4,
        self()
      )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end
  end

  def notice_checkout_error(
        _event,
        _measurements,
        %{
          error: %DBConnection.ConnectionError{
            message: "connection not available and queuing is disabled",
            reason: :error
          },
          opts: opts
        },
        parent
      ) do
    send(
      parent,
      {:notice_checkout_refused, self(), Keyword.get(opts, :queue), Keyword.get(opts, :deadline)}
    )
  end

  def notice_checkout_error(_event, _measurements, _metadata, _parent), do: :ok

  defp warm_repository do
    # Establish both actual default-busy connections before queue:false product
    # calls. Repository child startup itself does not mean its pools are ready.
    parent = self()

    ready =
      Task.async(fn ->
        IsolatedRepo.checkout(fn ->
          send(parent, :first_connection_ready)

          receive do
            :release_ready_connection -> :ok
          end
        end)
      end)

    assert_receive :first_connection_ready
    assert %{rows: [[5_000]]} = IsolatedRepo.query!("PRAGMA busy_timeout")
    send(ready.pid, :release_ready_connection)
    assert :ok = Task.await(ready)
  end

  defp scope(n),
    do: %{
      owner_id: "human_notice_owner",
      target_agent_id: "agent_notice_target",
      engagement_id:
        "eng_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")
    }

  defp put_engagement(scope) do
    IsolatedRepo.insert!(%Engagement{
      engagement_id: scope.engagement_id,
      agent_id: scope.target_agent_id,
      owner_tenant: scope.owner_id,
      scope: "user",
      visibility: "private",
      updated_at: ~U[2020-01-01 00:00:00.000000Z]
    })
  end

  defp value(scope, n, text \\ nil, kind \\ "notification", recipient \\ "human_notice_subject") do
    id = "notice_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")
    text = text || "notice#{n}"

    payload = [
      "arbor.notice.provenance.v1",
      scope.owner_id,
      scope.target_agent_id,
      scope.engagement_id,
      recipient,
      id,
      kind,
      text
    ]

    {:ok, taint} =
      Taint.new(%{
        level: :untrusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :unverified,
        source: "native_conversation_notice",
        chain: []
      })

    {:ok, envelope} = TaintEnvelope.new(payload, taint)
    {:ok, persisted} = TaintEnvelope.to_map(envelope)

    %{
      notice_id: id,
      recipient_subject_id: recipient,
      kind: kind,
      text: text,
      provenance: %{"origin" => "native_action", "taint" => persisted}
    }
  end
end
