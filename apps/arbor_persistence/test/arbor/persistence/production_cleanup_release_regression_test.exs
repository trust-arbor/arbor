defmodule Arbor.Persistence.ProductionCleanupReleaseRegressionTest do
  use ExUnit.Case, async: false

  # Build an isolated production release first, then include this tag with
  # ARBOR_PERSISTENCE_RELEASE pointing at its bin/arbor_persistence executable.
  @moduletag :isolated_repo
  @moduletag :integration
  @moduletag timeout: 120_000

  @fixture Path.expand("../../support/production_cleanup_release_fixture.exs", __DIR__)

  test "release regression: public SQL cleanup works without Mix and preserves foreign tenants" do
    executable = System.fetch_env!("ARBOR_PERSISTENCE_RELEASE")
    assert File.regular?(executable)

    private_dir =
      Path.join(System.tmp_dir!(), "arbor-cleanup-release-#{System.unique_integer([:positive])}")

    File.mkdir_p!(private_dir)
    empty_env = Path.join(private_dir, "empty.env")
    File.write!(empty_env, "")
    on_exit(fn -> File.rm_rf!(private_dir) end)

    expression =
      "Code.require_file(#{inspect(@fixture)}); Arbor.Persistence.ProductionCleanupReleaseFixture.run()"

    {output, status} =
      System.cmd(executable, ["eval", expression],
        stderr_to_stdout: true,
        env: [
          {"ARBOR_DB", "sqlite"},
          {"ARBOR_ENV_PATH", empty_env},
          {"ARBOR_HOME", Path.join(private_dir, "home")},
          {"ARBOR_DATA_DIR", Path.join(private_dir, "data")},
          {"ARBOR_SECURITY_STATE_DIR", Path.join(private_dir, "security")},
          {"ARBOR_PERSISTENCE_RELEASE_DATABASE", Path.join(private_dir, "cleanup.sqlite3")},
          # The shared production config requires an endpoint secret, even though
          # this cold storage consumer never starts an endpoint. Use only test data.
          {"SECRET_KEY_BASE", String.duplicate("isolated-release-test-secret-", 4)},
          {"ERL_CRASH_DUMP", Path.join(private_dir, "erl_crash.dump")},
          {"ERL_FLAGS", "+S 4:4"}
        ]
      )

    IO.write(output)
    assert status == 0, output
    assert output =~ "PUBLIC_PRODUCTION_CLEANUP_NO_MIX_OK"
  end
end
