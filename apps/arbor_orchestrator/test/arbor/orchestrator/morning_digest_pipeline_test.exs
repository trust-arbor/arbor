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
    temporary =
      Path.join(System.tmp_dir!(), "arbor-digest-engine-#{System.unique_integer([:positive])}")

    for topic <- ["upstream-deps", "upstream-deps-summary", "morning-digest"] do
      File.mkdir_p!(Path.join([temporary, "reports", topic]))
    end

    {:ok, workdir} = SafePath.resolve_real(temporary)
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity(identity)

    resources = [
      "arbor://orchestrator/execute",
      "arbor://action/reports/build_morning_digest",
      "arbor://fs/read/#{String.trim_leading(workdir, "/")}/reports/upstream-deps/**",
      "arbor://fs/read/#{String.trim_leading(workdir, "/")}/reports/upstream-deps-summary/**",
      "arbor://fs/write/#{String.trim_leading(workdir, "/")}/reports/morning-digest/**"
    ]

    caps =
      for uri <- resources do
        {:ok, cap} = Security.grant(principal: identity.agent_id, resource: uri)
        cap
      end

    on_exit(fn ->
      for cap <- caps, do: Security.revoke(cap.id)
      Security.deregister_identity(identity.agent_id)
      File.rm_rf!(temporary)
    end)

    %{workdir: workdir, identity: identity, caps: caps}
  end

  test "real signed run_file_as reaches the bounded digest action without a provider", fixture do
    input = Path.join([fixture.workdir, "reports/upstream-deps", "#{Date.utc_today()}.md"])
    File.write!(input, "engine input")
    assert {:ok, result} = run(fixture)
    assert {:ok, :success} = Orchestrator.classify_run_result(result)
    assert "build_digest" in result.completed_nodes
    output = Path.join([fixture.workdir, "reports/morning-digest", "#{Date.utc_today()}.md"])
    assert File.read!(output) =~ "engine input"
  end

  test "security regression: actual Engine failure is an unsuccessful result envelope", fixture do
    Security.revoke(List.last(fixture.caps).id)
    assert {:ok, result} = run(fixture)
    assert {:error, {:pipeline_outcome, :fail}} = Orchestrator.classify_run_result(result)
    output = Path.join([fixture.workdir, "reports/morning-digest", "#{Date.utc_today()}.md"])
    refute File.exists?(output)
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
