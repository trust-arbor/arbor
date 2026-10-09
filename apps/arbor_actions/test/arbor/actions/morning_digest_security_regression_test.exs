defmodule Arbor.Actions.MorningDigestSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Reports.BuildMorningDigest
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression
  @params %{reports_directory: "reports", topics: ["upstream-deps", "upstream-deps-summary"]}
  @resource "arbor://action/reports/build_morning_digest"

  setup do
    :ok = ensure_ready_run_lease!()

    temporary = Path.join(System.tmp_dir!(), "arbor-digest-#{System.unique_integer([:positive])}")

    for topic <- ["upstream-deps", "upstream-deps-summary", "morning-digest"] do
      File.mkdir_p!(Path.join([temporary, "reports", topic]))
    end

    {:ok, workdir} = SafePath.resolve_real(temporary)
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity_fixture(identity)

    resources = [
      @resource,
      "arbor://fs/read/#{String.trim_leading(workdir, "/")}/reports/upstream-deps/**",
      "arbor://fs/read/#{String.trim_leading(workdir, "/")}/reports/upstream-deps-summary/**",
      "arbor://fs/write/#{String.trim_leading(workdir, "/")}/reports/morning-digest/**"
    ]

    caps =
      for resource <- resources do
        {:ok, cap} = Security.grant_fixture(principal: identity.agent_id, resource: resource)
        cap
      end

    on_exit(fn ->
      for cap <- caps, do: Security.revoke_fixture(cap.id)
      Security.deregister_identity_fixture(identity.agent_id)
      File.rm_rf!(temporary)
    end)

    %{identity: identity, workdir: workdir, caps: caps, date: Date.to_iso8601(Date.utc_today())}
  end

  test "authenticated pipeline-internal action publishes both bounded reports and replaces its own digest",
       fixture do
    File.write!(report(fixture, "upstream-deps"), "first report")
    File.write!(report(fixture, "upstream-deps-summary"), "second report")
    File.write!(report(fixture, "morning-digest"), "obsolete output")

    assert {:ok, result} = execute(fixture)
    assert result.path == report(fixture, "morning-digest")
    assert result.included_topics == @params.topics
    assert result.missing_topics == []
    contents = File.read!(result.path)
    assert contents =~ "## upstream-deps\n\nfirst report"
    assert contents =~ "## upstream-deps-summary\n\nsecond report"
    refute contents =~ "obsolete output"
    assert result.bytes_written == byte_size(contents)
    assert File.ls!(Path.dirname(result.path)) == ["#{fixture.date}.md"]
  end

  test "security regression: a valid action grant and signed proof do not expose the default public route",
       fixture do
    assert {:error, :pipeline_internal_not_exposed} = execute(fixture, @params, false)
    refute File.exists?(report(fixture, "morning-digest"))
    assert File.ls!(Path.dirname(report(fixture, "morning-digest"))) == []
  end

  test "missing inputs are explicit and never read other topic directories", fixture do
    File.mkdir_p!(Path.join(fixture.workdir, "reports/private"))
    File.write!(report(fixture, "private"), "DO-NOT-READ")
    assert {:ok, result} = execute(fixture)
    assert result.missing_topics == @params.topics
    refute File.read!(result.path) =~ "DO-NOT-READ"
  end

  test "security regression: direct run and forged context cannot acquire the action principal",
       fixture do
    assert {:error, :action_principal_authority_required} =
             BuildMorningDigest.run(@params, %{
               agent_id: fixture.identity.agent_id,
               workdir: fixture.workdir
             })

    refute File.exists?(report(fixture, "morning-digest"))
  end

  test "security regression: source read capability is required even for missing files",
       fixture do
    Security.revoke_fixture(Enum.at(fixture.caps, 1).id)
    assert {:error, _} = execute(fixture)
    refute File.exists?(report(fixture, "morning-digest"))
  end

  test "security regression: revoked write capability preserves the old output and creates no temporary file",
       fixture do
    output = report(fixture, "morning-digest")
    File.write!(output, "preserve")
    Security.revoke_fixture(List.last(fixture.caps).id)
    assert {:error, _} = execute(fixture)
    assert File.read!(output) == "preserve"
    assert File.ls!(Path.dirname(output)) == ["#{fixture.date}.md"]
  end

  test "security regression: symlink input and destination are refused", fixture do
    secret = Path.join(fixture.workdir, "secret")
    File.write!(secret, "secret")
    File.ln_s!(secret, report(fixture, "upstream-deps"))
    assert {:error, :report_not_regular} = execute(fixture)
    File.rm!(report(fixture, "upstream-deps"))
    File.ln_s!(secret, report(fixture, "morning-digest"))
    assert {:error, :report_not_regular} = execute(fixture)
    assert File.read!(secret) == "secret"
  end

  test "security regression: symlink topic directory is refused even inside the workdir",
       fixture do
    directory = Path.join(fixture.workdir, "reports/upstream-deps")
    other = Path.join(fixture.workdir, "other")
    File.mkdir!(other)
    File.rmdir!(directory)
    File.ln_s!(other, directory)
    assert {:error, :report_directory_not_canonical} = execute(fixture)
    refute File.exists?(report(fixture, "morning-digest"))
  end

  test "oversized or invalid UTF8 input leaves output unchanged", fixture do
    output = report(fixture, "morning-digest")
    File.write!(output, "old")
    input = report(fixture, "upstream-deps")
    File.write!(input, String.duplicate("x", 256 * 1024 + 1))
    assert {:error, :report_too_large} = execute(fixture)
    assert File.read!(output) == "old"
    File.write!(input, <<255>>)
    assert {:error, :invalid_report_encoding} = execute(fixture)
    assert File.read!(output) == "old"
  end

  test "security regression: arbitrary directories, topics and missing workdir are refused",
       fixture do
    assert {:error, :invalid_digest_parameters} =
             execute(fixture, %{@params | reports_directory: "../reports"})

    assert {:error, :invalid_digest_parameters} =
             execute(fixture, %{@params | topics: ["private"]})

    assert {:error, :canonical_workdir_required} = execute(%{fixture | workdir: nil})
  end

  test "security regression: a supplied absent or malformed routine token cannot authorize digest I/O",
       fixture do
    for token <- [
          nil,
          %{},
          %{lease: "lease_" <> String.duplicate("a", 24), token: String.duplicate("b", 43)}
        ] do
      {:ok, proof} =
        SignedRequest.sign(@resource, fixture.identity.agent_id, fixture.identity.private_key)

      assert {:error, _} =
               Actions.authorize_and_execute(
                 fixture.identity.agent_id,
                 BuildMorningDigest,
                 @params,
                 %{
                   signed_request: proof,
                   workdir: fixture.workdir,
                   taint_policy: :permissive,
                   allow_pipeline_internal: true,
                   routine_effect_token: token
                 }
               )

      refute File.exists?(report(fixture, "morning-digest"))
      assert File.ls!(Path.dirname(report(fixture, "morning-digest"))) == []
    end
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

  defp execute(fixture, params \\ @params, pipeline_internal? \\ true) do
    {:ok, proof} =
      SignedRequest.sign(@resource, fixture.identity.agent_id, fixture.identity.private_key)

    context = %{
      signed_request: proof,
      workdir: fixture.workdir,
      taint_policy: :permissive
    }

    # Source-selected graph-syscall exposure still requires the real signed
    # principal, action capability, and every path-scoped FileGuard check.
    context =
      if pipeline_internal?, do: Map.put(context, :allow_pipeline_internal, true), else: context

    Actions.authorize_and_execute(fixture.identity.agent_id, BuildMorningDigest, params, context)
  end

  defp report(fixture, topic),
    do: Path.join([fixture.workdir, "reports", topic, "#{fixture.date}.md"])
end
