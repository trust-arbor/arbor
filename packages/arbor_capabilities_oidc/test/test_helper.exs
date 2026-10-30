Code.require_file("support/loopback_http_server.ex", __DIR__)
Code.require_file("support/token_fixture.ex", __DIR__)

ExUnit.start()

# HTTP and JWT providers and the pool are explicit test-owned resources.
# Starting the package itself starts no provider process or network pool.
for app <- [:joken, :finch, :req] do
  {:ok, _started} = Application.ensure_all_started(app)
end

{:ok, pool_supervisor} =
  Supervisor.start_link([Arbor.Common.OAuth.HttpClient.Pool], strategy: :one_for_one)

Process.unlink(pool_supervisor)

ExUnit.after_suite(fn _result ->
  if Process.alive?(pool_supervisor), do: Supervisor.stop(pool_supervisor)
end)
