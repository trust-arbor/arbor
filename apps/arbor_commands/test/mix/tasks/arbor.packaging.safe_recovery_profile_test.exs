defmodule Mix.Tasks.Arbor.Packaging.SafeRecoveryProfileTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.SafeRecoveryProfile
  alias Arbor.Commands.SafeRecoveryProfile.Encode
  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Packaging.SafeRecoveryProfile, as: Task

  @moduletag :fast

  setup do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "parser rejects unknown, positional, repeated, conflicting, and negative input", %{
    root: root
  } do
    write_fixed_profile!(root, committed_bytes())

    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--write"])
    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--review", "x"])
    assert {:error, {:arguments, :unexpected_positional}} = Task.execute(["extra"])

    assert {:error, {:arguments, {:repeated_option, :check}}} =
             Task.execute(["--check", "--check"])

    assert {:error, {:arguments, {:repeated_option, :root}}} =
             Task.execute(["--root", "a", "--root", "a"])

    assert {:error, {:arguments, {:conflicting_option, :check}}} =
             Task.execute(["--check", "--no-check"])

    assert {:error, {:arguments, {:repeated_option, :check}}} =
             Task.execute(["--check=true", "--check=true"])

    assert {:error, {:arguments, {:conflicting_option, :check}}} =
             Task.execute(["--check=true", "--check=false"])

    assert {:error, {:arguments, {:repeated_option, :json}}} =
             Task.execute(["--json", "--json=true"])

    assert {:error, {:arguments, {:conflicting_option, :json}}} =
             Task.execute(["--json=true", "--json=false"])

    assert {:error, {:arguments, {:conflicting_option, :root}}} =
             Task.execute(["--root", "a", "--root", "b"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :json}}} =
             Task.execute(["--no-json"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :check}}} =
             Task.execute(["--no-check"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :check}}} =
             Task.execute(["--check=false"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :json}}} =
             Task.execute(["--json=false"])

    assert {:ok, %{"mode" => "check"}} =
             Task.execute(["--root", root, "--check=true"])

    assert {:ok, %{"output" => "json"}} =
             Task.execute(["--root", root, "--json=true"])

    assert {:error, {:arguments, :invalid_argv}} = Task.execute([:check])
  end

  test "production task rejects every runtime hook before execution" do
    assert {:error, {:production_task_forbids_runtime_hooks, [:profile]}} =
             Task.execute(["--json"], profile: %{})

    assert {:error, {:production_task_forbids_runtime_hooks, [:candidate]}} =
             Task.execute([], candidate: %{})

    assert {:error, {:production_task_forbids_runtime_hooks, [:decoder]}} =
             Task.execute(["--check"], decoder: Jason)

    assert {:error, :invalid_runtime_opts} = Task.execute([], [:profile])
  end

  test "report and check emit admitted evidence without calling architecture ready", %{
    root: root
  } do
    write_fixed_profile!(root, committed_bytes())

    assert {:ok, report} = SafeRecoveryProfile.run(root: root)
    assert {:ok, check} = SafeRecoveryProfile.run(root: root, mode: "check")
    assert {:ok, digest} = Encode.profile_digest(report["profile"])

    expected_human =
      "safe-recovery-profile report profile=safe_recovery " <>
        "evidence_status=conformant architecture_status=blocked " <>
        "blockers=13 digest=#{digest}"

    assert {:ok, ^expected_human} = Task.render_report(report, false)
    refute expected_human =~ "ready"
    refute expected_human =~ "pass"

    check_human =
      "safe-recovery-profile check profile=safe_recovery " <>
        "evidence_status=conformant architecture_status=blocked " <>
        "blockers=13 digest=#{digest}"

    assert {:ok, ^check_human} = Task.render_report(check, false)
    refute check_human =~ "ready"
    refute check_human =~ "pass"

    old = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      output =
        capture_io(fn ->
          assert :ok = Task.finish_report(report, %{mode: "report", json: false})
          assert :ok = Task.finish_report(check, %{mode: "check", json: false})
        end)

      assert output =~ expected_human
      assert output =~ check_human
    after
      Mix.shell(old)
    end

    assert Task.exit_reason("report", report) == :ok
    assert Task.exit_reason("check", check) == :ok
    assert check["profile"]["architecture_status"] == "blocked"
  end

  test "JSON output is deterministic and binds the same profile digest", %{root: root} do
    write_fixed_profile!(root, committed_bytes())

    assert {:ok, result} =
             SafeRecoveryProfile.run(root: root, json: true, mode: "check")

    assert {:ok, first} = Task.render_report(result, true)
    assert {:ok, second} = Task.render_report(result, true)
    assert first == second
    refute String.contains?(first, "\n")

    assert {:ok, decoded} = Jason.decode(first)
    assert decoded["mode"] == "check"
    assert decoded["output"] == "json"
    assert decoded["profile_digest"] == result["profile_digest"]
    assert {:ok, digest} = Encode.profile_digest(decoded["profile"])
    assert digest == decoded["profile_digest"]
    assert digest == result["profile_digest"]
    assert decoded["profile"]["evidence_status"] == "conformant"
    assert decoded["profile"]["architecture_status"] == "blocked"
    refute Map.has_key?(decoded["profile"], "profile_digest")

    assert {:ok, executed} = Task.execute(["--root", root, "--check", "--json"])
    assert executed["profile_digest"] == digest
    assert {:ok, rendered} = Task.render_report(executed, true)
    assert rendered == first
  end

  test "root quality alias contains exactly one safe_recovery check after platform_inventory" do
    assert {:ok, root} = PackagingRoot.resolve(nil)
    contents = File.read!(Path.join(root, "mix.exs"))

    assert contents =~
             ~r/arbor\.packaging\.platform_inventory --check",\n\s+"arbor\.packaging\.safe_recovery_profile --check"/

    assert length(Regex.scan(~r/arbor\.packaging\.safe_recovery_profile --check/, contents)) ==
             1
  end

  defp committed_path do
    Application.app_dir(:arbor_commands, "priv/packaging/safe_recovery_profile.v1.json")
  end

  defp committed_bytes, do: File.read!(committed_path())

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-safe-recovery-task-#{System.unique_integer([:positive, :monotonic])}"
      )

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"] do
      path = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# marker\n")
    end

    {:ok, real_root} = SafePath.resolve_real(root)
    real_root
  end

  defp write_fixed_profile!(root, bytes) when is_binary(bytes) do
    path = Path.join(root, SafeRecoveryProfile.default_profile_path())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end
end
