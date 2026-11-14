defmodule Mix.Tasks.Arbor.HomeMigrationTest do
  @moduledoc """
  Shell and task tests for the one-time `~/.arbor/distribution/.arbor`
  migration, on scratch trees only (never the operator's real home).
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Helpers
  alias Mix.Tasks.Arbor.Home.Migrate
  alias Mix.Tasks.Arbor.HomeMigration
  alias Mix.Tasks.Arbor.HomeMigrationCore, as: Core

  # Noon UTC keeps the local calendar date on 2026-02-14 in any common zone.
  @feb_utc {{2026, 2, 14}, {12, 0, 0}}

  setup do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    home = Path.join(system_tmp, "arbor-home-migration-#{token}/.arbor")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(Path.dirname(home)) end)

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    {:ok, home: home}
  end

  # The owner's case: a February target key, an October legacy key, a
  # legacy-only ledger and marker, and an empty legacy retention directory.
  defp owner_fixture(home) do
    legacy = Helpers.legacy_home_root(home)

    write(home, "security/master.key", "february-master-key")
    File.touch!(Path.join(home, "security/master.key"), @feb_utc)
    write(home, "logs/arbor-dev.log", "log")

    write(legacy, "security/master.key", "october-master-key")
    write(legacy, "security/capability_revocations.v1.json", ~s({"v":1,"revoked":[]}))
    write(legacy, "security/.initialized", "")
    File.mkdir_p!(Path.join(legacy, "workspace_retention"))

    write(Helpers.distribution_cookie_home(home), ".erlang.cookie", "cookie\n")
    legacy
  end

  defp write(root, rel, contents) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp archive_rel do
    {{y, m, d}, _} = :calendar.universal_time_to_local_time(@feb_utc)
    "security/master.key.pre-home-migration-" <> Enum.map_join([y, m, d], &pad/1)
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp shell_output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, _level, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  test "owner case applies: October key wins, February key archived, ledger moved", %{home: home} do
    legacy = owner_fixture(home)

    assert {:ok, plan} = HomeMigration.plan(home)
    assert Core.applicable?(plan)
    assert {:ok, done} = HomeMigration.apply_plan(plan, home)
    assert done == plan.ops

    assert File.read!(Path.join(home, "security/master.key")) == "october-master-key"
    assert File.read!(Path.join(home, archive_rel())) == "february-master-key"

    assert File.read!(Path.join(home, "security/capability_revocations.v1.json")) ==
             ~s({"v":1,"revoked":[]})

    assert File.regular?(Path.join(home, "security/.initialized"))
    refute File.exists?(Path.join(home, "workspace_retention"))
    refute File.exists?(legacy)
    refute HomeMigration.legacy_state_present?(home)

    # The cookie directory itself is not legacy state.
    assert File.read!(Helpers.distribution_cookie_file(home)) == "cookie\n"
    assert File.read!(Path.join(home, "logs/arbor-dev.log")) == "log"
  end

  test "stops at the first failure and reports what was done", %{home: home} do
    owner_fixture(home)
    assert {:ok, plan} = HomeMigration.plan(home)

    # Something takes the archive name after planning.
    write(home, archive_rel(), "squatter")

    assert {:error, %{done: done, failed: {failed_op, reason}, remaining: remaining}} =
             HomeMigration.apply_plan(plan, home)

    assert done == [
             {:move, "security/.initialized", :regular},
             {:move, "security/capability_revocations.v1.json", :regular}
           ]

    assert {:replace, "security/master.key", _} = failed_op
    assert {:exists, _} = reason
    assert {:remove_empty_dir, ""} = List.last(remaining)

    # Nothing was lost: both keys and the squatter are intact.
    assert File.read!(Path.join(home, "security/master.key")) == "february-master-key"

    assert File.read!(Path.join(Helpers.legacy_home_root(home), "security/master.key")) ==
             "october-master-key"

    assert File.read!(Path.join(home, archive_rel())) == "squatter"
    assert HomeMigration.legacy_state_present?(home)
  end

  test "a legacy symlink blocks and is never followed", %{home: home} do
    legacy = Helpers.legacy_home_root(home)
    outside = Path.join(Path.dirname(home), "outside-secret")
    File.write!(outside, "do not read")
    File.mkdir_p!(Path.join(legacy, "skills"))
    File.ln_s!(outside, Path.join(legacy, "skills/evil"))

    assert {:ok, plan} = HomeMigration.plan(home)
    refute Core.applicable?(plan)
    assert {"skills/evil", :unsupported_legacy_kind} in plan.blocked

    Migrate.run(["--arbor-home", home])
    assert shell_output() =~ "skills/evil  legacy entry is a symlink or special file"

    assert catch_exit(Migrate.run(["--apply", "--arbor-home", home])) == {:shutdown, 1}
    assert File.exists?(Path.join(legacy, "skills/evil"))
  end

  test "dry run prints the plan and changes nothing", %{home: home} do
    legacy = owner_fixture(home)
    Migrate.run(["--arbor-home", home])
    output = shell_output()

    assert output =~ "Legacy daemon state: #{legacy}"
    assert output =~ "replace  security/master.key  (legacy copy wins)"
    assert output =~ "current security/master.key is kept as #{archive_rel()}"
    assert output =~ "move     security/capability_revocations.v1.json"
    assert output =~ "move     security/.initialized"
    assert output =~ "rmdir    workspace_retention/ (no files left)"
    assert output =~ "Dry run: nothing changed"

    assert File.read!(Path.join(home, "security/master.key")) == "february-master-key"
    assert File.dir?(Path.join(legacy, "workspace_retention"))
  end

  test "--apply migrates when no managed daemon is recorded", %{home: home} do
    owner_fixture(home)
    Migrate.run(["--apply", "--arbor-home", home])
    assert shell_output() =~ "Applied 6 operations"
    assert File.read!(Path.join(home, "security/master.key")) == "october-master-key"
    refute HomeMigration.legacy_state_present?(home)
    refute File.exists?(Helpers.lock_dir(home))
  end

  test "--apply refuses when the recorded daemon state cannot be verified", %{home: home} do
    owner_fixture(home)
    File.write!(Helpers.pid_file(home), "not-a-pid")

    assert catch_exit(Migrate.run(["--apply", "--arbor-home", home])) == {:shutdown, 1}
    assert shell_output() =~ "Cannot verify that the managed Arbor daemon is stopped"
    assert File.read!(Path.join(home, "security/master.key")) == "february-master-key"
  end

  test "no legacy tree means nothing to do", %{home: home} do
    Migrate.run(["--arbor-home", home])
    assert shell_output() =~ "Nothing to do"
  end
end
