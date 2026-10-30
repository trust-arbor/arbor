defmodule Arbor.Security.ApplicationStartupFailureTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  import ExUnit.CaptureLog

  alias Arbor.Security.Application, as: SecurityApplication

  # 2026-10-09: a pre-authenticated-record store failed the dev boot with a
  # bare :offline_migration_required and nothing naming the directory or the
  # (only) recovery. The startup error must carry both.
  test "an offline-migration hydration failure names the store directory and the recovery" do
    {result, log} =
      with_log(fn ->
        SecurityApplication.actionable_startup_failure(
          {:authority_store_hydration_failed, :offline_migration_required}
        )
      end)

    assert {:authority_store_hydration_failed, :offline_migration_required,
            %{authority_root: root, action: action}} = result

    assert is_binary(root)
    assert action =~ root
    assert action =~ "mv "
    assert action =~ "fresh store"
    assert log =~ "Authority store needs offline migration"
  end

  test "other startup failures pass through unchanged" do
    reason = {:authority_store_hydration_failed, :record_authentication_failed}
    assert SecurityApplication.actionable_startup_failure(reason) == reason
  end
end
