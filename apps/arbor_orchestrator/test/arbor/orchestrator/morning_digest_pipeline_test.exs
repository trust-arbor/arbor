defmodule Arbor.Orchestrator.MorningDigestPipelineTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator
  alias Arbor.Security

  @moduletag :fast
  @pipeline Path.expand("../../../../arbor_scheduler/priv/pipelines/morning_digest.dot", __DIR__)
  @args %{
    "reports_directory" => "reports",
    "topics" => ["upstream-deps", "upstream-deps-summary"]
  }

  setup do
    # The digest action asks the lease store whether this principal is bound
    # to a routine. A down store is :routine_lease_unavailable. An empty ready
    # store means the direct engine run is not routine-bound.
    :ok = ensure_ready_run_lease!()

    temporary =
      Path.join(System.tmp_dir!(), "arbor-digest-engine-#{System.unique_integer([:positive])}")

    for topic <- ["upstream-deps", "upstream-deps-summary", "morning-digest"] do
      File.mkdir_p!(Path.join([temporary, "reports", topic]))
    end

    {:ok, workdir} = SafePath.resolve_real(temporary)
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity_fixture(identity)

    resources = [
      "arbor://orchestrator/execute",
      "arbor://action/reports/build_morning_digest",
      "arbor://fs/read/#{String.trim_leading(workdir, "/")}/reports/upstream-deps/**",
      "arbor://fs/read/#{String.trim_leading(workdir, "/")}/reports/upstream-deps-summary/**",
      "arbor://fs/write/#{String.trim_leading(workdir, "/")}/reports/morning-digest/**"
    ]

    caps =
      for uri <- resources do
        {:ok, cap} = Security.grant_fixture(principal: identity.agent_id, resource: uri)
        cap
      end

    on_exit(fn ->
      for cap <- caps, do: Security.revoke_fixture(cap.id)
      Security.deregister_identity_fixture(identity.agent_id)
      File.rm_rf!(temporary)
    end)

    %{workdir: workdir, identity: identity, caps: caps}
  end

  test "real signed run_file_as reaches the bounded digest action without a provider", fixture do
    input = Path.join([fixture.workdir, "reports/upstream-deps", "#{Date.utc_today()}.md"])
    File.write!(input, "engine input")
    assert {:ok, result} = run(fixture)
    classification = Orchestrator.classify_run_result(result)

    assert classification == {:ok, :success},
           """
           digest failed: #{inspect(classification)}
           outcome: #{inspect(result.final_outcome)}
           nodes: #{inspect(result.completed_nodes)}
           reasons: #{inspect(Map.get(result, :node_failure_reasons))}
           """

    assert "build_digest" in result.completed_nodes
    output = Path.join([fixture.workdir, "reports/morning-digest", "#{Date.utc_today()}.md"])
    assert File.read!(output) =~ "engine input"
  end

  test "security regression: actual Engine failure is an unsuccessful result envelope", fixture do
    Security.revoke_fixture(List.last(fixture.caps).id)
    assert {:ok, result} = run(fixture)
    assert {:error, {:pipeline_outcome, :fail}} = Orchestrator.classify_run_result(result)
    output = Path.join([fixture.workdir, "reports/morning-digest", "#{Date.utc_today()}.md"])
    refute File.exists?(output)
  end

  # The lease store answers routine checks only after its reconciler runs, and
  # that reconciler is admitted only as a child of the scheduler runtime
  # supervisor. An ExUnit-owned supervisor stays in recovery forever.
  defp ensure_ready_run_lease! do
    {:ok, _} = Application.ensure_all_started(:arbor_scheduler)

    case Process.whereis(Arbor.Scheduler.RunLeaseSupervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        token =
          case Application.fetch_env(:arbor_scheduler, :test_scheduler_mutation_token) do
            {:ok, token} ->
              token

            :error ->
              token = make_ref()
              Application.put_env(:arbor_scheduler, :test_scheduler_mutation_token, token)
              token
          end

        case Supervisor.start_child(
               Arbor.Scheduler.Supervisor,
               {Arbor.Scheduler.RunLeaseSupervisor, scheduler_mutation_token: token}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "run lease supervisor failed to start: #{inspect(reason)}"
        end
    end

    await_run_lease_ready!()
  end

  defp await_run_lease_ready!(attempts \\ 200) do
    probe = "agent_" <> String.duplicate("0", 64)

    case Arbor.Scheduler.RunLease.routine_requirement(probe) do
      {:ok, required?} when is_boolean(required?) ->
        :ok

      {:error, :recovery_in_progress} when attempts > 0 ->
        Process.sleep(10)
        await_run_lease_ready!(attempts - 1)

      other ->
        raise "run lease did not leave recovery: #{inspect(other)}"
    end
  end

  defp run(fixture) do
    signer = Security.make_signer(fixture.identity.agent_id, fixture.identity.private_key)

    Orchestrator.run_file_as(@pipeline, fixture.identity.agent_id, signer,
      workdir: fixture.workdir,
      initial_values: @args,
      logs_root: Path.join(fixture.workdir, "logs")
    )
  end
end
