defmodule Mix.Tasks.Arbor.Packaging.SafeRecoveryArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.SafeRecoveryArtifact
  alias Arbor.Commands.SafeRecoveryArtifact.{Encode, Envelope, InputEvidence}
  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Packaging.SafeRecoveryArtifact, as: Task

  @moduletag :fast

  @overlay_bytes "synthetic-vec0-dylib-bytes-for-input-evidence"
  @overlay_rel "deps/sqlite_vec/priv/0.1.5/vec0.dylib"
  @envelope_rel "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json"
  @payload_rel "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"

  setup do
    {root, observed, _manifest, _payload} = planted_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, observed: observed}
  end

  test "parser rejects unknown, positional, repeated, conflicting, and negative input" do
    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--dest", "/tmp/x"])
    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--out", "x.json"])
    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--manifest", "m"])
    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--jsonx"])
    assert {:error, {:arguments, :unexpected_positional}} = Task.execute(["extra"])
    assert {:error, {:arguments, :unexpected_positional}} = Task.execute(["--json", "x"])

    assert {:error, {:arguments, {:repeated_option, :check}}} =
             Task.execute(["--check", "--check"])

    assert {:error, {:arguments, {:repeated_option, :build_verify}}} =
             Task.execute(["--build-verify", "--build-verify"])

    assert {:error, {:arguments, {:repeated_option, :write}}} =
             Task.execute(["--write", "--write"])

    assert {:error, {:arguments, {:repeated_option, :root}}} =
             Task.execute(["--root", "a", "--root", "a"])

    assert {:error, {:arguments, {:conflicting_option, :check}}} =
             Task.execute(["--check", "--no-check"])

    assert {:error, {:arguments, {:repeated_option, :check}}} =
             Task.execute(["--check=true", "--check=true"])

    assert {:error, {:arguments, {:conflicting_option, :check}}} =
             Task.execute(["--check=true", "--check=false"])

    assert {:error, {:arguments, {:conflicting_option, :json}}} =
             Task.execute(["--json=true", "--json=false"])

    assert {:error, {:arguments, {:conflicting_option, :root}}} =
             Task.execute(["--root", "a", "--root", "b"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :check}}} =
             Task.execute(["--no-check"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :check}}} =
             Task.execute(["--check=false"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :json}}} =
             Task.execute(["--no-json"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :json}}} =
             Task.execute(["--json=false"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :build_verify}}} =
             Task.execute(["--no-build-verify"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :build_verify}}} =
             Task.execute(["--build-verify=false"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :write}}} =
             Task.execute(["--no-write"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :write}}} =
             Task.execute(["--write=false"])

    assert {:error, {:arguments, :invalid_argv}} = Task.execute([:check])
    assert {:error, {:arguments, :invalid_argv}} = Task.execute("check")
  end

  test "parser rejects conflicting mode selection" do
    assert {:error, {:arguments, {:conflicting_mode, ["--check", "--build-verify"]}}} =
             Task.execute(["--check", "--build-verify"])

    assert {:error, {:arguments, {:conflicting_mode, ["--build-verify", "--check"]}}} =
             Task.execute(["--build-verify", "--check"])

    assert {:error, {:arguments, {:conflicting_mode, ["--write", "--check"]}}} =
             Task.execute(["--write", "--check"])

    assert {:error, {:arguments, {:conflicting_mode, ["--check", "--build-verify", "--write"]}}} =
             Task.execute(["--check", "--build-verify", "--write"])
  end

  test "production task rejects every runtime hook before execution" do
    assert {:error, {:production_task_forbids_runtime_hooks, [:destination]}} =
             Task.execute([], destination: "/tmp/evil")

    assert {:error, {:production_task_forbids_runtime_hooks, [:writer]}} =
             Task.execute([], writer: fn _ -> :ok end)

    assert {:error, {:production_task_forbids_runtime_hooks, [:manifest]}} =
             Task.execute(["--check"], manifest: %{})

    assert {:error, {:production_task_forbids_runtime_hooks, [:decoder]}} =
             Task.execute(["--check"], decoder: Jason)

    assert {:error, {:production_task_forbids_runtime_hooks, [:executable]}} =
             Task.execute(["--check"], executable: "mix")

    assert {:error, {:production_task_forbids_runtime_hooks, [:sandbox]}} =
             Task.execute(["--check"], sandbox: :unconfined)

    assert {:error, :invalid_runtime_opts} = Task.execute([], [:destination])
  end

  test "report mode emits admitted evidence against the committed pair", %{
    root: root,
    observed: observed
  } do
    assert {:ok, result} = Task.execute(["--root", root])
    assert result["mode"] == "report"
    assert result["schema"] == Encode.schema()
    assert result["reproducibility_status"] == "identical"
    assert result["payload_byte_size"] > 0

    assert {:ok, human} = Task.render_report(result, false)

    assert human ==
             "safe-recovery-artifact report schema=#{Encode.schema()} " <>
               "evidence_status=conformant architecture_status=blocked " <>
               "findings=#{result["findings_count"]} reproducibility=identical " <>
               "digest=#{result["manifest_digest"]}"

    refute human =~ "ready"
    refute human =~ "pass"
    _ = observed
  end

  test "check mode renders deterministically and routes the overlay through the pinned production descriptor",
       %{root: root, observed: observed} do
    # The synthetic overlay cannot satisfy the pinned production descriptor,
    # so --check fails closed at the overlay binding -- proving the CLI takes
    # no overlay override.
    assert {:error, :overlay_digest_mismatch} = Task.execute(["--root", root, "--check"])

    # With the pair absent, --check fails earlier with :artifact_missing.
    bare = bare_root!()
    on_exit(fn -> File.rm_rf!(bare) end)
    assert {:error, :artifact_missing} = Task.execute(["--root", bare, "--check"])

    # Check-mode rendering is exercised on a check-shaped result: render is
    # a pure function of the admitted result envelope.
    assert {:ok, report} = Task.execute(["--root", root])

    human_checked =
      report
      |> Map.put("mode", "check")
      |> Map.merge(%{
        "inputs_checked" => length(observed.inputs),
        "head_commit" => observed.commit,
        "head_tree" => observed.tree
      })

    assert {:ok, human} = Task.render_report(human_checked, false)

    assert human =~
             " inputs=#{length(observed.inputs)} head=#{observed.commit} tree=#{observed.tree}"

    refute human =~ "ready"

    checked = Map.put(human_checked, "output", "json")

    assert {:ok, first} = Task.render_report(checked, true)
    assert {:ok, second} = Task.render_report(checked, true)
    assert first == second
    refute String.contains?(first, "\n")

    assert {:ok, decoded} = Jason.decode(first)
    assert decoded["mode"] == "check"
    assert decoded["output"] == "json"
    assert decoded["inputs_checked"] == length(observed.inputs)
    assert decoded["head_commit"] == observed.commit
    assert decoded["head_tree"] == observed.tree
  end

  test "check fails closed with :artifact_missing on a bare root" do
    root = bare_root!()
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :artifact_missing} = Task.execute(["--root", root, "--check"])
  end

  test "finish_report and exit_reason for every mode", %{root: root} do
    assert {:ok, report} = Task.execute(["--root", root])
    assert :ok = Task.exit_reason("report", report)
    assert :ok = Task.exit_reason("check", report)
    assert :ok = Task.exit_reason("build_verify", report)
    assert :ok = Task.exit_reason("write", report)
    assert {:shutdown, 1} = Task.exit_reason("report", :not_a_map)
    assert {:shutdown, 1} = Task.exit_reason(:bogus, %{})

    old = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      output =
        capture_io(fn ->
          assert :ok = Task.finish_report(report, %{mode: "report", json: false})
        end)

      assert output =~ "safe-recovery-artifact report schema="
    after
      Mix.shell(old)
    end

    assert {:error, {:invalid_result_field, "mode"}} = Task.render_report(%{}, false)
    assert {:error, :invalid_result_render} = Task.render_report(:nope, false)
  end

  test "build_verify and write report renders", %{root: root} do
    assert {:ok, checked} = Task.execute(["--root", root])
    verified = Map.put(checked, "mode", "build_verify")

    assert {:error, {:invalid_result_field, "committed_manifest_digest"}} =
             Task.render_report(verified, false)

    build_verify_result =
      verified
      |> Map.merge(%{
        "committed_manifest_digest" => String.duplicate("a", 64),
        "fresh_manifest_digest" => String.duplicate("a", 64),
        "equality" => "verified"
      })

    assert {:ok, line} = Task.render_report(build_verify_result, false)
    assert line =~ " committed_digest=#{String.duplicate("a", 64)}"
    assert line =~ " fresh_digest=#{String.duplicate("a", 64)}"
    assert line =~ " equality=verified"

    write_result =
      verified
      |> Map.merge(%{
        "written_paths" => [
          "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json",
          "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"
        ]
      })

    assert {:ok, write_line} = Task.render_report(Map.put(write_result, "mode", "write"), false)
    assert write_line =~ " wrote=2 payload_sha256="

    # The JSON renderer must emit the written path list, not fail on it.
    write_json_result = write_result |> Map.put("mode", "write") |> Map.put("output", "json")

    assert {:ok, write_json} = Task.render_report(write_json_result, true)
    assert {:ok, write_decoded} = Jason.decode(write_json)

    assert write_decoded["written_paths"] == [
             "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json",
             "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"
           ]

    assert write_decoded["mode"] == "write"
    assert write_decoded["payload_sha256"] == write_result["payload_sha256"]

    assert {:error, {:invalid_result_field, "written_paths"}} =
             Task.render_report(Map.put(verified, "mode", "write"), false)
  end

  test "root quality alias runs exactly one cheap artifact check after the profile check" do
    assert {:ok, root} = PackagingRoot.resolve(nil)
    contents = File.read!(Path.join(root, "mix.exs"))

    assert contents =~
             ~r/arbor\.packaging\.safe_recovery_profile --check",\n\s+"arbor\.packaging\.safe_recovery_artifact --check"/

    assert length(Regex.scan(~r/arbor\.packaging\.safe_recovery_artifact --check/, contents)) ==
             1

    quality = quality_alias_body(contents)
    refute quality =~ "--build-verify"
    refute quality =~ "--write"
  end

  # -- helpers -----------------------------------------------------------------

  defp planted_root! do
    root = bare_root!()
    write_rel!(root, @overlay_rel, @overlay_bytes)
    git!(root, ["init", "--quiet"])
    git!(root, ["add", "-A"])
    git!(root, ["commit", "--quiet", "-m", "init"])

    {:ok, real} = SafePath.resolve_real(root)

    {:ok, observed} =
      InputEvidence.observe(
        real,
        30_000,
        {:expected, byte_size(@overlay_bytes), sha256_hex(@overlay_bytes)}
      )

    {manifest, payload_bytes} = plant_artifact!(real, observed)
    {real, observed, manifest, payload_bytes}
  end

  defp bare_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-safe-recovery-mix-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)

    for rel <-
          Arbor.Commands.SafeRecoveryArtifact.SourcePolicy.required_files() ++
            ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_trust/lib/trust.ex"] do
      write_rel!(root, rel, "# marker\n")
    end

    root
  end

  defp plant_artifact!(root, observed) do
    alias Arbor.Commands.TwoBuildFactFixture, as: TB

    lease =
      TB.source_lease()
      |> Map.merge(%{
        "commit" => observed.commit,
        "tree" => observed.tree,
        "object_format" => observed.object_format,
        "build_inputs" => observed.inputs
      })

    facts =
      TB.facts()
      |> put_in([:replies, {:stage_source, :a}], {:ok, lease})
      |> put_in([:replies, {:stage_source, :b}], {:ok, lease})

    {:ok, manifest} =
      SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: facts})

    {:ok, payload_bytes} = Encode.encode_manifest(manifest)
    {:ok, envelope} = Envelope.build(payload_bytes)
    {:ok, envelope_bytes} = Envelope.encode(envelope)

    write_rel!(root, @envelope_rel, envelope_bytes)
    write_rel!(root, @payload_rel, payload_bytes)
    {manifest, payload_bytes}
  end

  defp write_rel!(root, rel, bytes) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp git!(root, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.email=arbor@test", "-c", "user.name=arbor"] ++ args,
        cd: root,
        stderr_to_stdout: true
      )

    out
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp quality_alias_body(contents) do
    case Regex.run(~r/quality:\s*\[([^\]]*)\]/s, contents) do
      [_full, body] -> body
      nil -> flunk("no quality alias found in root mix.exs")
    end
  end
end
