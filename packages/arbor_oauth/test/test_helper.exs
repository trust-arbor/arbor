ExUnit.start()

# Owning protocol tests exercise the real bounded Req adapter. Provider apps
# and the one dedicated pool are explicit test resources, not package startup.
for app <- [:finch, :req] do
  {:ok, _started} = Application.ensure_all_started(app)
end

{:ok, pool_supervisor} =
  Supervisor.start_link([Arbor.Common.OAuth.HttpClient.Pool], strategy: :one_for_one)

Process.unlink(pool_supervisor)

ExUnit.after_suite(fn _result ->
  if Process.alive?(pool_supervisor), do: Supervisor.stop(pool_supervisor)
end)
