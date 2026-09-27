# Run only in an isolated checkout with the test umbrella already compiled.
root = Path.join(System.tmp_dir!(), "arbor-conversation-runner-#{System.pid()}")
File.mkdir_p!(root)
repo = Arbor.Persistence.Repo

Application.put_env(
  :arbor_persistence,
  repo,
  Application.get_env(:arbor_persistence, repo, [])
  |> Keyword.put(:database, Path.join(root, "fallback.sqlite3"))
)

Mix.Task.run("test", [
  "--no-compile",
  "apps/arbor_agent/test/arbor/agent/conversation_entrypoint_journey_test.exs",
  "--include",
  "isolated_repo",
  "--include",
  "database",
  "--seed",
  "0"
])
