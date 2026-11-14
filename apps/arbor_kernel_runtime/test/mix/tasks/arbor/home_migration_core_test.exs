defmodule Mix.Tasks.Arbor.HomeMigrationCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Mix.Tasks.Arbor.HomeMigrationCore, as: Core

  @feb {{2026, 2, 14}, {9, 30, 0}}
  @oct {{2026, 10, 21}, {18, 5, 0}}

  defp file(contents, mtime \\ @oct) do
    %{
      kind: :regular,
      size: byte_size(contents),
      digest: :crypto.hash(:sha256, contents),
      mtime: mtime
    }
  end

  defp dir, do: %{kind: :directory}

  describe "owner case (2026-11-13 decision)" do
    setup do
      legacy = %{
        "security" => dir(),
        "security/master.key" => file("october key bytes"),
        "security/capability_revocations.v1.json" => file(~s({"revoked":[]})),
        "security/.initialized" => file(""),
        "workspace_retention" => dir()
      }

      target = %{
        "security" => dir(),
        "security/master.key" => file("february key bytes", @feb),
        "logs" => dir(),
        "arbor-dev.meta.json" => file("{}")
      }

      {:ok, plan: Core.plan(legacy, target)}
    end

    test "legacy master.key wins and the February copy is archived, never deleted", %{plan: plan} do
      assert {:replace, "security/master.key", "security/master.key.pre-home-migration-20260214"} in plan.ops
      refute Enum.any?(plan.ops, &match?({:remove_identical, "security/master.key"}, &1))
    end

    test "legacy-only revocation ledger and .initialized move", %{plan: plan} do
      assert {:move, "security/capability_revocations.v1.json", :regular} in plan.ops
      assert {:move, "security/.initialized", :regular} in plan.ops
    end

    test "empty legacy workspace_retention/ is removed, not moved", %{plan: plan} do
      assert {:remove_empty_dir, "workspace_retention"} in plan.ops
      refute Enum.any?(plan.ops, &match?({:move, "workspace_retention", _}, &1))
    end

    test "the plan is applicable and ends by removing the legacy root", %{plan: plan} do
      assert Core.applicable?(plan)

      assert plan.ops == [
               {:move, "security/.initialized", :regular},
               {:move, "security/capability_revocations.v1.json", :regular},
               {:replace, "security/master.key",
                "security/master.key.pre-home-migration-20260214"},
               {:remove_empty_dir, "security"},
               {:remove_empty_dir, "workspace_retention"},
               {:remove_empty_dir, ""}
             ]
    end
  end

  test "a byte-identical legacy file is dropped" do
    plan = Core.plan(%{"skills.json" => file("same")}, %{"skills.json" => file("same", @feb)})
    assert plan.ops == [{:remove_identical, "skills.json"}, {:remove_empty_dir, ""}]
  end

  test "a same-size file with different bytes is a conflict, not identical" do
    plan = Core.plan(%{"k" => file("aaaa")}, %{"k" => file("bbbb", @feb)})
    assert {:replace, "k", "k.pre-home-migration-20260214"} in plan.ops
  end

  test "a legacy directory missing from the target moves whole" do
    legacy = %{"skills" => dir(), "skills/a" => dir(), "skills/a/SKILL.md" => file("x")}
    plan = Core.plan(legacy, %{})
    assert plan.ops == [{:move, "skills", :directory}, {:remove_empty_dir, ""}]
  end

  test "nested empty directories are removed deepest first" do
    legacy = %{"w" => dir(), "w/a" => dir(), "w/a/b" => dir(), "w/c" => dir()}
    plan = Core.plan(legacy, %{"w" => dir()})

    assert plan.ops == [
             {:remove_empty_dir, "w/a/b"},
             {:remove_empty_dir, "w/a"},
             {:remove_empty_dir, "w/c"},
             {:remove_empty_dir, "w"},
             {:remove_empty_dir, ""}
           ]
  end

  describe "blocking conflicts" do
    test "a legacy symlink blocks, even deep inside a directory that would move" do
      legacy = %{"skills" => dir(), "skills/link" => %{kind: :symlink}, "skills/f" => file("x")}
      plan = Core.plan(legacy, %{})
      refute Core.applicable?(plan)
      assert {"skills/link", :unsupported_legacy_kind} in plan.blocked
    end

    test "a target symlink blocks" do
      plan = Core.plan(%{"k" => file("x")}, %{"k" => %{kind: :symlink}})
      assert plan.blocked == [{"k", :unsupported_target_kind}]
    end

    test "a file facing a directory blocks both ways" do
      assert Core.plan(%{"k" => file("x")}, %{"k" => dir()}).blocked == [{"k", :kind_mismatch}]

      assert Core.plan(%{"d" => dir(), "d/f" => file("x")}, %{"d" => file("y")}).blocked ==
               [{"d", :kind_mismatch}]
    end

    test "an archive name that already exists blocks instead of overwriting" do
      legacy = %{"k" => file("new")}
      target = %{"k" => file("old", @feb), "k.pre-home-migration-20260214" => file("older")}
      assert Core.plan(legacy, target).blocked == [{"k", :archive_name_taken}]
    end

    test "a legacy distribution/ entry would land in the cookie directory and blocks" do
      legacy = %{"distribution" => dir(), "distribution/.erlang.cookie" => file("c")}
      plan = Core.plan(legacy, %{"distribution" => dir()})
      assert plan.blocked == [{"distribution", :reserved_path}]
      refute Enum.any?(plan.ops, &match?({_, "distribution" <> _, _}, &1))
    end

    test "uncomparable contents block" do
      plan = Core.plan(%{"k" => %{kind: :regular, size: 1}}, %{"k" => file("y")})
      assert plan.blocked == [{"k", :missing_digest}]
    end
  end

  describe "SQLite databases" do
    test "a legacy database with any family member in the target blocks" do
      plan =
        Core.plan(%{"arbor_dev.db" => file("empty")}, %{"arbor_dev.db" => file("migrated", @feb)})

      assert plan.blocked == [{"arbor_dev.db", :sqlite_family_conflict}]

      # A legacy WAL must never land beside a different main file.
      plan = Core.plan(%{"arbor_dev.db-wal" => file("wal")}, %{"arbor_dev.db" => file("main")})
      assert plan.blocked == [{"arbor_dev.db-wal", :sqlite_family_conflict}]
    end

    test "a database only in the legacy tree moves with its siblings" do
      legacy = %{"x.sqlite3" => file("db"), "x.sqlite3-wal" => file("wal")}
      plan = Core.plan(legacy, %{"other.db" => file("o")})
      assert Core.applicable?(plan)
      assert {:move, "x.sqlite3", :regular} in plan.ops
      assert {:move, "x.sqlite3-wal", :regular} in plan.ops
    end
  end

  test "archive_path/2 zero-pads the date" do
    assert Core.archive_path("a/b", {{2026, 3, 7}, {0, 0, 0}}) ==
             "a/b.pre-home-migration-20260307"
  end

  test "admit_apply/1 admits only a confirmed-absent daemon" do
    assert :ok = Core.admit_apply(:absent)
    assert :ok = Core.admit_apply(:no_such_process)
    assert :ok = Core.admit_apply(:present_not_arbor)
    assert {:refuse, {:daemon_running, "n@h"}} = Core.admit_apply({:verified_arbor, "n@h"})
    assert {:refuse, :daemon_state_unverified} = Core.admit_apply(:unverified)
  end

  test "describe/1 names every operation and the blockers" do
    plan = Core.plan(%{"k" => file("new"), "l" => %{kind: :symlink}}, %{"k" => file("old", @feb)})
    text = Enum.join(Core.describe(plan), "\n")
    assert text =~ "replace  k  (legacy copy wins)"
    assert text =~ "kept as k.pre-home-migration-20260214"
    assert text =~ "Blocked"
    assert text =~ "l  legacy entry is a symlink or special file"
  end

  # Mechanical CRC guard: the planner must stay pure (see functional-core skill).
  test "the planner core contains no impure calls" do
    src =
      File.read!(Path.expand("../../../../lib/mix/tasks/arbor/home_migration_core.ex", __DIR__))

    for re <- [
          ~r/\bFile\./,
          ~r/\bSystem\./,
          ~r/DateTime\.utc_now/,
          ~r/:rand\./,
          ~r/:crypto\./,
          ~r/\bMix\.shell/,
          ~r/\bProcess\./,
          ~r/:os\./,
          ~r/Application\.get_env/
        ] do
      refute Regex.match?(re, src), "impure pattern #{inspect(re.source)} in HomeMigrationCore"
    end
  end
end
