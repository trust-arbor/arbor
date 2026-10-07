defmodule Arbor.Orchestrator.HandlerDispatchEvidenceSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-007"

  import ExUnit.CaptureLog

  @moduletag :fast

  alias Arbor.Orchestrator.Handlers.StartHandler

  @tag :security_regression
  @tag spec: "KSEC-007"
  test "security regression: public pipeline execution records exact handler module and code digest" do
    {StartHandler, beam, _path} = :code.get_object_code(StartHandler)
    expected_sha256 = Base.encode16(:crypto.hash(:sha256, beam), case: :lower)
    parent = self()
    :ok = Logger.put_module_level(Arbor.Orchestrator.Engine, :info)
    on_exit(fn -> Logger.delete_module_level(Arbor.Orchestrator.Engine) end)

    dot = """
    digraph HandlerEvidence {
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    logs_root = scratch_dir!("arbor-handler-evidence")

    log =
      capture_log([level: :info], fn ->
        assert {:ok, result} =
                 Arbor.Orchestrator.run(dot,
                   cache: false,
                   logs_root: logs_root,
                   on_event: fn event -> send(parent, {:pipeline_event, event}) end
                 )

        assert result.final_outcome.status == :success
      end)

    assert_receive {:pipeline_event,
                    %{
                      type: :stage_started,
                      node_id: "start",
                      handler_module: "Arbor.Orchestrator.Handlers.StartHandler",
                      handler_sha256: ^expected_sha256
                    }}

    assert log =~ "orchestrator handler dispatch"
    assert log =~ "node_id=\"start\""
    assert log =~ "handler_module=Arbor.Orchestrator.Handlers.StartHandler"
    assert log =~ "handler_sha256=#{expected_sha256}"
  end

  defp scratch_dir!(prefix) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "#{prefix}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
