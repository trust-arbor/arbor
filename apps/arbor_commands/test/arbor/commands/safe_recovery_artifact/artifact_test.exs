defmodule Arbor.Commands.SafeRecoveryArtifact.ArtifactTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryArtifact
  alias Arbor.Commands.SafeRecoveryArtifact.{CommittedStore, Encode, Envelope, InputEvidence}
  alias Arbor.Commands.TwoBuildFactFixture, as: TB
  alias Arbor.Common.SafePath

  @moduletag :fast

  @overlay_bytes "synthetic-vec0-dylib-bytes-for-input-evidence"
  @overlay_rel "deps/sqlite_vec/priv/0.1.5/vec0.dylib"
  @envelope_rel "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json"
  @payload_rel "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"

  setup do
    {root, observed} = root_with_observed_inputs!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, observed: observed}
  end

  describe "report/1" do
    test "admits the planted committed pair and binds its digests", %{
      root: root,
      observed: observed
    } do
      {manifest, payload_bytes} = plant_artifact!(root, observed)

      assert {:ok, result} = SafeRecoveryArtifact.report(root: root)
      assert result["mode"] == "report"
      assert result["schema"] == Encode.schema()
      assert result["reproducibility_status"] == "identical"
      assert result["payload_byte_size"] == byte_size(payload_bytes)
      assert result["payload_sha256"] == sha256_hex(payload_bytes)
      assert {:ok, digest} = Encode.manifest_digest(manifest)
      assert result["manifest_digest"] == digest
    end

    test "an envelope whose digest disagrees with the payload bytes fails closed", %{
      root: root,
      observed: observed
    } do
      _ = plant_artifact!(root, observed)
      envelope_path = Path.join(root, @envelope_rel)
      {:ok, envelope} = envelope_path |> File.read!() |> Jason.decode()

      wrong_sha = %{
        envelope
        | "payload" => %{envelope["payload"] | "sha256" => String.duplicate("e", 64)}
      }

      {:ok, wrong_bytes} = Envelope.encode(wrong_sha)
      File.write!(envelope_path, wrong_bytes)

      assert {:error, :payload_digest_mismatch} = SafeRecoveryArtifact.report(root: root)

      wrong_size = %{envelope | "payload" => %{envelope["payload"] | "byte_size" => 7}}
      {:ok, size_bytes} = Envelope.encode(wrong_size)
      File.write!(envelope_path, size_bytes)

      assert {:error, :payload_size_mismatch} = SafeRecoveryArtifact.report(root: root)
    end

    test "an absent pair fails closed with :artifact_missing", %{root: root} do
      assert {:error, :artifact_missing} = SafeRecoveryArtifact.report(root: root)
    end

    test "malformed committed files fail closed", %{root: root} do
      File.mkdir_p!(Path.join(root, Path.dirname(@envelope_rel)))
      File.write!(Path.join(root, @envelope_rel), "{not json")
      File.write!(Path.join(root, @payload_rel), "{}")

      assert {:error, :invalid_envelope_json} = SafeRecoveryArtifact.report(root: root)
    end
  end

  describe "check/1 cheap complete input binding" do
    test "binds every fixed input at HEAD including the overlay", %{
      root: root,
      observed: observed
    } do
      _ = plant_artifact!(root, observed)

      assert {:ok, result} =
               SafeRecoveryArtifact.check_for_test(
                 root: root,
                 overlay_size: byte_size(@overlay_bytes),
                 overlay_sha256: sha256_hex(@overlay_bytes)
               )

      assert result["mode"] == "check"
      assert result["inputs_checked"] == length(observed.inputs)
      assert result["head_commit"] == observed.commit
      assert Enum.any?(observed.inputs, &(&1["path"] == @overlay_rel))
    end

    test "production overlay binding fails closed against a synthetic overlay", %{
      root: root,
      observed: observed
    } do
      _ = plant_artifact!(root, observed)
      assert {:error, :overlay_digest_mismatch} = SafeRecoveryArtifact.check(root: root)
    end

    test "fails closed with :artifact_missing before any git work on a bare root", %{root: root} do
      assert {:error, :artifact_missing} =
               SafeRecoveryArtifact.check_for_test(
                 root: root,
                 overlay_size: byte_size(@overlay_bytes),
                 overlay_sha256: sha256_hex(@overlay_bytes)
               )
    end

    test "a new file under a selected app root fails closed on the count", %{
      root: root,
      observed: observed
    } do
      _ = plant_artifact!(root, observed)
      commit_file!(root, "apps/arbor_trust/lib/extra.ex", "defmodule Extra do\nend\n")

      assert {:error, {:input_count_mismatch, committed, observed_count}} =
               SafeRecoveryArtifact.check_for_test(
                 root: root,
                 overlay_size: byte_size(@overlay_bytes),
                 overlay_sha256: sha256_hex(@overlay_bytes)
               )

      assert committed == length(observed.inputs)
      assert observed_count == committed + 1
    end

    test "an amended selected file fails closed on the digest", %{root: root, observed: observed} do
      _ = plant_artifact!(root, observed)

      File.write!(Path.join(root, "apps/arbor_trust/lib/trust.ex"), "defmodule T do\nend\n")
      git!(root, ["add", "-A"])
      git!(root, ["commit", "--quiet", "-m", "amend"])

      assert {:error, {:input_digest_mismatch, "apps/arbor_trust/lib/trust.ex"}} =
               SafeRecoveryArtifact.check_for_test(
                 root: root,
                 overlay_size: byte_size(@overlay_bytes),
                 overlay_sha256: sha256_hex(@overlay_bytes)
               )
    end

    test "a dropped input at equal count fails closed as missing", %{
      root: root,
      observed: observed
    } do
      {manifest, _payload} = plant_artifact!(root, observed)

      source = manifest["source"]
      dropped = Enum.reject(source["build_inputs"], &(&1["path"] == "config/prod.exs"))
      ghost = [%{"path" => "zz_ghost", "sha256" => String.duplicate("a", 64)}]
      changed = Enum.sort_by(dropped ++ ghost, & &1["path"])
      {:ok, inputs_digest} = Encode.build_inputs_digest(changed)

      tampered =
        %{manifest | "source" => %{source | "build_inputs" => changed}}
        |> put_in(["source", "build_inputs_digest"], inputs_digest)

      {:ok, payload_bytes} = Encode.encode_manifest(tampered)
      {:ok, envelope} = Envelope.build(payload_bytes)
      {:ok, envelope_bytes} = Envelope.encode(envelope)

      File.write!(Path.join(root, @payload_rel), payload_bytes)
      File.write!(Path.join(root, @envelope_rel), envelope_bytes)

      # At equal count the committed ghost path (absent from HEAD) is the
      # reported missing input; the silently dropped config file is the
      # unreached extra direction.
      assert {:error, {:missing_build_input, "zz_ghost"}} =
               SafeRecoveryArtifact.check_for_test(
                 root: root,
                 overlay_size: byte_size(@overlay_bytes),
                 overlay_sha256: sha256_hex(@overlay_bytes)
               )
    end
  end

  describe "build_verify/1 and write/1 closed options" do
    test "reject unknown options before any trusted-build or compose is attempted", %{
      root: root
    } do
      assert {:error, {:invalid_opt, :compose_hook}} =
               SafeRecoveryArtifact.build_verify(root: root, compose_hook: fn -> :ok end)

      assert {:error, {:invalid_opt, :executable}} =
               SafeRecoveryArtifact.build_verify(executable: "mix")

      assert {:error, {:invalid_opt, :timeout_ms}} =
               SafeRecoveryArtifact.build_verify(timeout_ms: 0)

      assert {:error, {:invalid_opt, :sandbox}} =
               SafeRecoveryArtifact.write(root: root, sandbox: :unconfined)

      assert {:error, {:invalid_opt, :digest}} =
               SafeRecoveryArtifact.write(digest: String.duplicate("a", 64))
    end

    test "reject non-keyword arguments", %{root: root} do
      assert {:error, :invalid_opts} = SafeRecoveryArtifact.report(%{root: root})
      assert {:error, :invalid_opts} = SafeRecoveryArtifact.check({:root, root})
      assert {:error, :invalid_opts} = SafeRecoveryArtifact.build_verify("root")
      assert {:error, :invalid_opts} = SafeRecoveryArtifact.write(:root)
    end
  end

  describe "write_from_manifest_for_test/2" do
    test "writes exactly the two committed paths and the readback admits", %{
      root: root,
      observed: observed
    } do
      {manifest, payload_bytes} = plant_artifact!(root, observed)

      File.rm!(Path.join(root, @envelope_rel))
      File.rm!(Path.join(root, @payload_rel))

      assert {:ok, result} =
               SafeRecoveryArtifact.write_from_manifest_for_test(manifest, root: root)

      assert result["mode"] == "write"
      assert result["written_paths"] == CommittedStore.paths()
      assert result["payload_sha256"] == sha256_hex(payload_bytes)

      assert Enum.sort(File.ls!(Path.join(root, "apps/arbor_commands/priv/packaging"))) == [
               "safe_recovery_artifact.payload.v1.json",
               "safe_recovery_artifact.v1.json"
             ]

      assert {:ok, _} = SafeRecoveryArtifact.report(root: root)
    end

    test "security regression: destination, write-hook, and repeat-write substitution fail closed",
         %{root: root, observed: observed} do
      {manifest, _payload} = plant_artifact!(root, observed)

      # An arbitrary destination opt does not exist; the only accepted opts
      # are the closed set, and every hook-shaped key is rejected by name.
      assert {:error, {:invalid_opt, :dest}} =
               SafeRecoveryArtifact.write_from_manifest_for_test(manifest, dest: "/tmp/evil")

      assert {:error, {:invalid_opt, :destination}} =
               SafeRecoveryArtifact.write_from_manifest_for_test(manifest,
                 root: root,
                 destination: "/tmp/evil"
               )

      assert {:error, {:invalid_opt, :writer}} =
               SafeRecoveryArtifact.write_from_manifest_for_test(manifest,
                 writer: fn _ -> :ok end
               )

      assert {:error, {:invalid_opt, :output_path}} =
               SafeRecoveryArtifact.write_from_manifest_for_test(manifest, output_path: "x.json")

      assert {:error, {:invalid_opt, :manifest}} =
               SafeRecoveryArtifact.write_from_manifest_for_test(manifest, manifest: %{})

      # Adversarial repeat-write: substitute the committed envelope with a
      # symlink to an outside target, then re-run the same write.
      outside =
        Path.join(
          System.tmp_dir!(),
          "arbor-artifact-outside-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(outside)

      try do
        target = Path.join(outside, "substitute.json")
        File.write!(target, "substitute target")
        File.rm!(Path.join(root, @envelope_rel))
        File.ln_s!(target, Path.join(root, @envelope_rel))

        assert {:error, :destination_symlink} =
                 SafeRecoveryArtifact.write_from_manifest_for_test(manifest, root: root)

        assert File.read!(target) == "substitute target"

        # Cleaning the symlink restores the closed two-path write.
        File.rm!(Path.join(root, @envelope_rel))

        assert {:ok, _} =
                 SafeRecoveryArtifact.write_from_manifest_for_test(manifest, root: root)

        assert {:ok, _} = SafeRecoveryArtifact.report(root: root)
      after
        File.rm_rf!(outside)
      end
    end

    test "a non-identical manifest is refused before any write", %{
      root: root,
      observed: observed
    } do
      {manifest, _payload} = plant_artifact!(root, observed)
      File.rm!(Path.join(root, @envelope_rel))
      File.rm!(Path.join(root, @payload_rel))

      repro = %{
        manifest["reproducibility"]
        | "payload_tree_digests" => [
            hd(manifest["reproducibility"]["payload_tree_digests"]),
            String.duplicate("c", 64)
          ]
      }

      different =
        %{manifest | "reproducibility" => Map.put(repro, "status", "different")}

      assert {:error, :reproducibility_mismatch} =
               SafeRecoveryArtifact.write_from_manifest_for_test(different, root: root)

      assert {:error, :artifact_missing} = SafeRecoveryArtifact.report(root: root)
    end

    test "rejects malformed manifests and non-keyword opts", %{root: root} do
      assert {:error, {:field_mismatch, _detail}} =
               SafeRecoveryArtifact.write_from_manifest_for_test(%{"schema" => "x"}, root: root)

      assert {:error, :invalid_opts} =
               SafeRecoveryArtifact.write_from_manifest_for_test(%{}, "not-opts")
    end
  end

  # -- root/fixture construction ------------------------------------------------

  defp root_with_observed_inputs! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-safe-recovery-artifact-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)

    for rel <- marker_files() do
      write_rel!(root, rel, "# marker\n")
    end

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

    {real, observed}
  end

  defp marker_files do
    Arbor.Commands.SafeRecoveryArtifact.SourcePolicy.required_files() ++
      ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_trust/lib/trust.ex"]
  end

  defp plant_artifact!(root, observed) do
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

  defp commit_file!(root, rel, contents) do
    write_rel!(root, rel, contents)
    git!(root, ["add", "-A"])
    git!(root, ["commit", "--quiet", "-m", "drift"])
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
end
