defmodule Arbor.Actions.Coding.PipelineInternalExposureSecurityRegressionTest do
  @moduledoc false
  # Order-independent proof that pipeline_internal actions are classified and
  # excluded from the central exposed catalog even when the module is not yet
  # loaded in the calling process. Production uses Code.ensure_loaded/1.
  use ExUnit.Case, async: false

  @moduletag :fast

  @target Arbor.Actions.Coding.DesignCheckpoint.Load

  setup do
    on_exit(fn ->
      _ = Code.ensure_loaded(@target)
    end)

    :ok
  end

  test "unloaded pipeline_internal action is classified and excluded from exposure" do
    # Two-step unload so the next ensure_loaded must re-read the on-disk BEAM.
    # delete/1 demotes current→old; purge/1 removes old. Best-effort if already
    # unloaded (delete returns false).
    _ = :code.purge(@target)
    _ = :code.delete(@target)
    _ = :code.purge(@target)
    refute :code.is_loaded(@target)

    # No preceding load of @target in this test body.
    assert Arbor.Actions.pipeline_internal_action?(@target)
    assert {:file, _path} = :code.is_loaded(@target)

    refute @target in Arbor.Actions.exposed_actions()

    exposed_catalog = Arbor.Actions.list_exposed_actions()

    refute Enum.any?(Map.values(exposed_catalog), fn modules ->
             @target in modules
           end)

    # Still present in the full (engine) catalog.
    assert @target in Arbor.Actions.list_actions()[:coding]
  end
end
