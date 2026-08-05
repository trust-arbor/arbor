defmodule Arbor.Persistence.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag :isolated_repo

  @root Path.expand("../../../../..", __DIR__)

  test "production SQLite configuration starts the persistence Repo and executes a query" do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_prod_repo_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    database = Path.join(temp_dir, "arbor_prod.sqlite3")
    deps_path = System.get_env("MIX_DEPS_PATH") || Path.join(@root, "deps")
    build_path = Path.join(@root, "_build/prod-repo-proof")

    probe = """
    repo_config =
      Application.fetch_env!(:arbor_persistence, Arbor.Persistence.Repo)

    required = [:database, :pool_size, :busy_timeout, :journal_mode]

    unless Enum.all?(required, &Keyword.has_key?(repo_config, &1)) do
      raise "production Repo configuration is incomplete"
    end

    unless repo_config[:database] == #{inspect(database)} do
      raise "production SQLite path was not runtime-resolved"
    end

    unless Application.fetch_env!(:arbor_persistence, :start_repo) do
      raise "production Repo supervision is disabled"
    end

    unless Arbor.Persistence.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
      raise "production Repo compiled with the wrong adapter"
    end

    {:ok, _started} = Application.ensure_all_started(:arbor_persistence)
    true = is_pid(Process.whereis(Arbor.Persistence.Repo))
    {:ok, %{rows: [[1]]}} = Arbor.Persistence.Repo.query("SELECT 1")
    true = File.exists?(#{inspect(database)})
    IO.puts("PROD_REPO_PROBE_OK")
    """

    env = [
      {"MIX_ENV", "prod"},
      {"ARBOR_DB", "sqlite"},
      {"ARBOR_DATA_DIR", temp_dir},
      {"ARBOR_SQLITE_PATH", nil},
      {"ARBOR_ENV_PATH", Path.join(temp_dir, "missing.env")},
      {"SECRET_KEY_BASE", String.duplicate("p", 64)},
      {"MIX_DEPS_PATH", deps_path},
      {"MIX_BUILD_PATH", build_path}
    ]

    assert {output, 0} =
             System.cmd(
               Path.join(@root, "bin/mix"),
               ["run", "--no-start", "-e", probe],
               cd: Path.join(@root, "apps/arbor_persistence"),
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "PROD_REPO_PROBE_OK"
  end
end
