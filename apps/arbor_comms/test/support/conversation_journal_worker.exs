# Standalone independent-BEAM qualifier. Run only with `mix run --no-start` in
# an isolated candidate and a newly-created qualification directory. No Arbor
# application is started, and the only Repo receives an explicit SQLite path.
# Arguments: ROOT DATABASE init|admit|hold-admit|claim|hold-claim|get|settle|events [ID] [VALUE]
# ROOT must be a pre-existing directory named conversation-journal-qualification-*.

[root, database, operation | args] = System.argv()
root = Path.expand(root)
database = Path.expand(database)

unless File.dir?(root) and
         String.starts_with?(Path.basename(root), "conversation-journal-qualification-") and
         Path.dirname(database) == root and Path.basename(database) == "journal.sqlite3" do
  raise "qualification requires an explicit isolated root and journal.sqlite3"
end

for app <- [:logger, :ecto_sql, :ecto_sqlite3, :jason],
    do: {:ok, _} = Application.ensure_all_started(app)

Logger.configure(level: :warning)
Code.require_file("conversation_journal_sqlite.exs", __DIR__)
alias Arbor.Comms.ConversationJournal, as: Journal
alias Arbor.Comms.TestConversationSQLite
alias Arbor.Comms.TestConversationSQLite.Repo

{:ok, _} =
  Repo.start_link(database: database, pool_size: 1, busy_timeout: 5_000, journal_mode: :wal)

TestConversationSQLite.configure()

scope = %{
  principal_id: "human_qualification",
  agent_id: "agent_qualification",
  engagement_id: "eng_qualification"
}

result =
  case {operation, args} do
    {"init", []} ->
      TestConversationSQLite.create_schema!(Repo)

    {"admit", [id, text]} ->
      Journal.admit(scope, %{id: id, text: text})

    {"hold-admit", [id, text]} ->
      Journal.admit(scope, %{id: id, text: text})

    {"claim", [id]} ->
      Journal.claim(scope, id)

    {"hold-claim", [id]} ->
      Journal.claim(scope, id)

    {"get", [id]} ->
      Journal.get(scope, id)

    {"settle", [id, token]} ->
      Journal.settle(scope, id, token, %{status: :completed, text: "qualified reply"})

    {"events", []} ->
      Journal.events(scope, 0)

    _ ->
      raise "invalid qualification operation"
  end

encoded =
  case result do
    :ok -> %{ok: true}
    {:ok, value} -> %{ok: true, value: value}
    {:error, reason} -> %{ok: false, error: inspect(reason)}
  end

encoded =
  Map.put(encoded, :runtime, %{
    elixir: System.version(),
    otp: to_string(:erlang.system_info(:otp_release)),
    os_pid: System.pid()
  })

IO.puts("JOURNAL_RESULT " <> Jason.encode!(encoded))

if operation in ["hold-admit", "hold-claim"] and match?({:ok, _}, result),
  do: Process.sleep(:infinity)
