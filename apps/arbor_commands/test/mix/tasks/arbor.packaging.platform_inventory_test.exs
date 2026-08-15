defmodule Mix.Tasks.Arbor.Packaging.PlatformInventoryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Commands.PlatformInventory
  alias Arbor.Commands.PlatformInventory.{Core, Encode}
  alias Arbor.Commands.SourceCoupling.GitInventory
  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Packaging.PlatformInventory, as: Task

  @moduletag :fast

  setup do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "parser rejects unknown, positional, repeated, conflicting, and negative input" do
    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--write"])
    assert {:error, {:arguments, :unexpected_positional}} = Task.execute(["extra"])

    assert {:error, {:arguments, {:repeated_option, :check}}} =
             Task.execute(["--check", "--check"])

    assert {:error, {:arguments, {:repeated_option, :root}}} =
             Task.execute(["--root", "a", "--root", "a"])

    assert {:error, {:arguments, {:conflicting_option, :check}}} =
             Task.execute(["--check", "--no-check"])

    assert {:error, {:arguments, {:conflicting_option, :review}}} =
             Task.execute(["--review", "a", "--review", "b"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :json}}} =
             Task.execute(["--no-json"])

    assert {:error, {:arguments, :invalid_argv}} = Task.execute([:check])
  end

  test "production task rejects every runtime hook before execution" do
    assert {:error, {:production_task_forbids_runtime_hooks, [:inventory]}} =
             Task.execute(["--json"], inventory: inventory())

    assert {:error, :invalid_runtime_opts} = Task.execute([], [:inventory])
  end

  test "report mode emits unreviewed and mismatch without failing", %{root: root} do
    assert {:ok, unreviewed} =
             PlatformInventory.run_for_test(root: root, inventory: inventory())

    stale = %{classification() | "blob_oid" => String.duplicate("b", 40)}

    assert {:ok, mismatch} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory(),
               classifications: [stale]
             )

    old = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      output =
        capture_io(fn ->
          assert :ok = Task.finish_report(unreviewed, %{mode: "report", json: false})
          assert :ok = Task.finish_report(mismatch, %{mode: "report", json: false})
        end)

      assert output =~ "platform-inventory report status=unreviewed"
      assert output =~ "platform-inventory report status=mismatch"
    after
      Mix.shell(old)
    end

    assert Task.exit_reason("report", "unreviewed") == :ok
    assert Task.exit_reason("report", "mismatch") == :ok
  end

  test "check mode exits nonzero unless status is match", %{root: root} do
    assert {:ok, unreviewed} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory(),
               mode: "check"
             )

    assert {:ok, match} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory(),
               classifications: [classification()],
               mode: "check"
             )

    old = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      capture_io(fn ->
        assert catch_exit(Task.finish_report(unreviewed, %{mode: "check", json: false})) ==
                 {:shutdown, 1}
      end)

      capture_io(fn ->
        assert :ok = Task.finish_report(match, %{mode: "check", json: false})
      end)
    after
      Mix.shell(old)
    end

    assert Task.exit_reason("check", "unreviewed") == {:shutdown, 1}
    assert Task.exit_reason("check", "mismatch") == {:shutdown, 1}
    assert Task.exit_reason("check", "match") == :ok
  end

  test "renders concise deterministic human output and canonical JSON", %{root: root} do
    assert {:ok, human_report} =
             PlatformInventory.run_for_test(root: root, inventory: inventory())

    assert {:ok, human} = Task.render_report(human_report, false)

    assert human ==
             "platform-inventory report status=unreviewed\n" <>
               "files=1 reviewed=0 unreviewed=1 failures=0"

    assert {:ok, json_report} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory(),
               classifications: [classification()],
               json: true
             )

    assert {:ok, expected} = Encode.encode_report(json_report)
    assert {:ok, ^expected} = Task.render_report(json_report, true)
    assert {:ok, ^expected} = Task.render_report(json_report, false)
    assert {:ok, decoded} = Jason.decode(expected)
    assert decoded["status"] == "match"
  end

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-platform-task-#{System.unique_integer([:positive, :monotonic])}"
      )

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"] do
      path = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# marker\n")
    end

    {:ok, real_root} = SafePath.resolve_real(root)
    real_root
  end

  defp inventory do
    source = file()

    {:ok, digest} =
      GitInventory.selected_index_digest([{source.path, source.mode, source.blob_oid}])

    %{
      files: [source],
      head_tree_oid: String.duplicate("a", 40),
      object_format: "sha1",
      selected_index_digest: digest
    }
  end

  defp file do
    bytes = "defmodule Arbor.Shell.PlatformTaskFixture do\nend\n"

    %{
      path: "apps/arbor_shell/lib/platform_task_fixture.ex",
      blob_oid: Core.git_blob_oid(bytes, "sha1"),
      mode: "100644",
      byte_size: byte_size(bytes),
      bytes: bytes
    }
  end

  defp classification do
    source = file()

    %{
      "path" => source.path,
      "blob_oid" => source.blob_oid,
      "class" => "trusted_host",
      "rationale" => "reviewed fixture"
    }
  end
end
