defmodule Arbor.Commands.SafeRecoveryProfileTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryProfile
  alias Arbor.Commands.SafeRecoveryProfile.{Core, Encode}
  alias Arbor.Common.SafePath

  @moduletag :fast
  @profile_opened_event [:arbor, :commands, :safe_recovery_profile, :opened]

  setup do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "production rejects every caller-supplied execution or data injection seam" do
    forbidden = [
      profile: %{},
      candidate: %{},
      review: "reviews/review.json",
      path: "apps/arbor_commands/priv/packaging/other.json",
      name: "safe_recovery",
      mfa: {__MODULE__, :profile, []},
      executable: "/bin/true",
      code_path: ".",
      module: __MODULE__,
      function: :profile,
      decoder: Jason,
      callback: fn -> :ok end,
      parser: Jason,
      inventory: %{},
      classifications: []
    ]

    for {key, value} <- forbidden do
      assert {:error, {:production_opts_forbid_synthetic, [^key]}} =
               SafeRecoveryProfile.run([{key, value}])
    end
  end

  test "strictly admits production option shape, keys, duplicates, values, and booleans" do
    assert {:error, :invalid_opts} = SafeRecoveryProfile.run(%{})
    assert {:error, :invalid_opts} = SafeRecoveryProfile.run([:mode])
    assert {:error, :invalid_opts} = SafeRecoveryProfile.run([{"mode", "check"}])
    assert {:error, :invalid_opts} = SafeRecoveryProfile.run([{:mode, "report", :extra}])

    assert {:error, {:duplicate_option, :mode}} =
             SafeRecoveryProfile.run(mode: "report", mode: "check")

    assert {:error, {:duplicate_option, :json}} =
             SafeRecoveryProfile.run(json: true, json: false)

    assert {:error, {:production_opts_forbid_synthetic, [:output]}} =
             SafeRecoveryProfile.run(output: "json")

    assert {:error, {:invalid_option, :mode}} = SafeRecoveryProfile.run(mode: :check)
    assert {:error, {:invalid_option, :mode}} = SafeRecoveryProfile.run(mode: "write")
    assert {:error, {:invalid_option, :json}} = SafeRecoveryProfile.run(json: 1)
    assert {:error, {:invalid_option, :root}} = SafeRecoveryProfile.run(root: 1)
  end

  test "report and check admit the fixed candidate under a marker-valid root", %{root: root} do
    write_fixed_profile!(root, committed_bytes())

    assert {:ok, report} = SafeRecoveryProfile.run(root: root)
    assert {:ok, check} = SafeRecoveryProfile.run(root: root, mode: "check", json: true)
    assert {:ok, report_again} = SafeRecoveryProfile.run(root: root, json: true)
    assert {:ok, json_again} = SafeRecoveryProfile.run(root: root, json: true)

    assert report["mode"] == "report"
    assert report["output"] == "human"
    assert check["mode"] == "check"
    assert check["output"] == "json"
    assert report_again == json_again

    assert report["profile"]["profile"] == "safe_recovery"
    assert report["profile"]["evidence_status"] == "conformant"
    assert report["profile"]["architecture_status"] == "blocked"
    assert length(report["profile"]["blockers"]) == 13
    refute Map.has_key?(report["profile"], "profile_digest")

    assert {:ok, digest} = Encode.profile_digest(report["profile"])
    assert report["profile_digest"] == digest
    assert check["profile_digest"] == digest
    assert report_again["profile_digest"] == digest
    assert {:ok, ^digest} = Encode.profile_digest(check["profile"])
  end

  test "run_for_test admits one synthetic profile and rejects extra seams", %{root: root} do
    candidate = load_candidate()

    assert {:ok, injected} =
             SafeRecoveryProfile.run_for_test(root: root, profile: candidate, mode: "check")

    assert injected["profile"]["evidence_status"] == "conformant"
    assert injected["profile"]["architecture_status"] == "blocked"

    assert {:error, {:unknown_option, :candidate}} =
             SafeRecoveryProfile.run_for_test(
               root: root,
               profile: candidate,
               candidate: candidate
             )

    assert {:error, {:invalid_option, :profile}} =
             SafeRecoveryProfile.run_for_test(root: root, profile: [])

    assert {:error, :profile_missing} = SafeRecoveryProfile.run_for_test(root: root)
  end

  test "missing fixed file is an error", %{root: root} do
    refute File.exists?(Path.join(root, SafeRecoveryProfile.default_profile_path()))

    assert {:error, :profile_missing} = SafeRecoveryProfile.run(root: root)
  end

  test "root and path escape attempts fail closed", %{root: root} do
    write_fixed_profile!(root, committed_bytes())

    assert {:error, :invalid_root_marker} = SafeRecoveryProfile.run(root: "../outside")
    assert {:error, :invalid_root_marker} = SafeRecoveryProfile.run(root: Path.dirname(root))
    assert {:error, {:root_path, :null_byte}} = SafeRecoveryProfile.run(root: "ok\0bad")

    outside = Path.join(Path.dirname(root), "outside-root")
    on_exit(fn -> File.rm_rf!(outside) end)
    assert {:error, :invalid_root_marker} = SafeRecoveryProfile.run(root: outside)
  end

  test "explicit root symlink is rejected", %{root: root} do
    write_fixed_profile!(root, committed_bytes())
    link = root <> "-link"
    on_exit(fn -> File.rm_rf!(link) end)
    :ok = File.ln_s(root, link)

    assert {:error, :root_symlink_redirection} = SafeRecoveryProfile.run(root: link)
  end

  test "candidate symlink inside the root is rejected", %{root: root} do
    target = Path.join(root, "apps/arbor_commands/priv/packaging/target.json")
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, committed_bytes())

    path = Path.join(root, SafeRecoveryProfile.default_profile_path())
    :ok = File.ln_s(target, path)

    assert {:error, :profile_symlink_redirection} = SafeRecoveryProfile.run(root: root)
  end

  test "candidate symlink outside the root is rejected", %{root: root} do
    outside = Path.join(Path.dirname(root), "outside-profile.json")
    on_exit(fn -> File.rm(outside) end)
    File.write!(outside, committed_bytes())

    path = Path.join(root, SafeRecoveryProfile.default_profile_path())
    File.mkdir_p!(Path.dirname(path))
    :ok = File.ln_s(outside, path)

    assert {:error, :profile_path_escape} = SafeRecoveryProfile.run(root: root)
  end

  test "security regression: pathname replacement after open cannot redirect profile bytes", %{
    root: root
  } do
    path = write_fixed_profile!(root, committed_bytes())
    original = path <> ".opened"
    outside = Path.join(Path.dirname(root), "outside-opened-profile.json")
    File.write!(outside, committed_bytes())
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    on_exit(fn ->
      :telemetry.detach(handler_id)
      File.rm_rf(outside)
      File.rm_rf(original)
    end)

    :ok =
      :telemetry.attach(
        handler_id,
        @profile_opened_event,
        fn _event, _measurements, %{path: opened_path}, _config ->
          File.rename!(opened_path, original)
          File.ln_s!(outside, opened_path)
          send(test_pid, :profile_path_replaced)
        end,
        nil
      )

    assert {:error, :profile_changed_during_read} = SafeRecoveryProfile.run(root: root)
    assert_receive :profile_path_replaced
    :telemetry.detach(handler_id)

    File.rm!(path)
    File.rename!(original, path)
  end

  test "security regression: a stalled descriptor read is bounded", %{root: root} do
    write_fixed_profile!(root, committed_bytes())
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        @profile_opened_event,
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :profile_reader_stalled)
          Process.sleep(5_000)
        end,
        nil
      )

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :profile_read_timeout} = SafeRecoveryProfile.run(root: root)
    assert_receive :profile_reader_stalled
    assert System.monotonic_time(:millisecond) - started_at < 2_500
  end

  test "directory and non-regular candidates are rejected", %{root: root} do
    path = Path.join(root, SafeRecoveryProfile.default_profile_path())
    File.mkdir_p!(path)

    assert {:error, :profile_not_regular} = SafeRecoveryProfile.run(root: root)
  end

  test "reader is bounded independently of stat size by the ceiling+1 path", %{root: root} do
    path = Path.join(root, SafeRecoveryProfile.default_profile_path())
    File.mkdir_p!(Path.dirname(path))
    max_profile_bytes = SafeRecoveryProfile.max_profile_bytes()
    {:ok, io} = File.open(path, [:write, :binary])

    try do
      assert {:ok, ^max_profile_bytes} = :file.position(io, max_profile_bytes)
      :ok = IO.binwrite(io, <<0>>)
    after
      File.close(io)
    end

    assert File.stat!(path).size == max_profile_bytes + 1
    assert {:error, :profile_too_large} = SafeRecoveryProfile.run(root: root)
  end

  test "invalid JSON and malformed, extra, or missing fields fail closed", %{root: root} do
    path = write_fixed_profile!(root, "[")

    assert {:error, :profile_invalid_json} = SafeRecoveryProfile.run(root: root)

    File.write!(path, "[]")
    assert {:error, :invalid_candidate} = SafeRecoveryProfile.run(root: root)

    candidate = load_candidate()
    File.write!(path, Jason.encode!(Map.delete(candidate, "blockers")))

    assert {:error, {:field_mismatch, %{missing: ["blockers"], extra_count: 0}}} =
             SafeRecoveryProfile.run(root: root)

    File.write!(path, Jason.encode!(Map.put(candidate, "extra", true)))

    assert {:error, {:field_mismatch, %{missing: [], extra_count: 1}}} =
             SafeRecoveryProfile.run(root: root)

    File.write!(path, Jason.encode!(%{candidate | "blockers" => "not-a-list"}))

    assert {:error, {:invalid_field, "blockers", :not_a_list}} =
             SafeRecoveryProfile.run(root: root)
  end

  test "stale source-inventory digest or count fails closed", %{root: root} do
    candidate = load_candidate()
    inventory = candidate["source_inventory"]

    write_fixed_profile!(
      root,
      Jason.encode!(%{
        candidate
        | "source_inventory" => %{
            inventory
            | "selected_index_digest" => String.duplicate("a", 64)
          }
      })
    )

    assert {:error, {:invalid_field, "selected_index_digest", :digest_mismatch}} =
             SafeRecoveryProfile.run(root: root)

    write_fixed_profile!(
      root,
      Jason.encode!(%{
        candidate
        | "source_inventory" => %{inventory | "selected_file_count" => 302}
      })
    )

    assert {:error, {:invalid_field, "selected_file_count", :count_mismatch}} =
             SafeRecoveryProfile.run(root: root)
  end

  test "reordered candidate lists fail even when Core would sort them", %{root: root} do
    candidate = load_candidate()
    assert {:ok, projected} = Core.project(candidate)

    for field <- [
          "selected_applications",
          "mandatory_host_responsibilities",
          "forbidden_facilities",
          "expected_external_dependencies",
          "blockers"
        ] do
      reordered = Map.put(candidate, field, Enum.reverse(candidate[field]))
      assert {:ok, ^projected} = Core.project(reordered)
      write_fixed_profile!(root, Jason.encode!(reordered))

      assert {:error, {:candidate_not_canonical, ^field}} =
               SafeRecoveryProfile.run(root: root)
    end
  end

  test "unsupported statuses fail closed", %{root: root} do
    candidate = load_candidate()

    write_fixed_profile!(
      root,
      Jason.encode!(%{candidate | "architecture_status" => "ready"})
    )

    assert {:error, {:invalid_field, "architecture_status", :unknown_architecture_status}} =
             SafeRecoveryProfile.run(root: root)

    write_fixed_profile!(
      root,
      Jason.encode!(%{candidate | "evidence_status" => "draft"})
    )

    assert {:error, {:invalid_field, "evidence_status", :unknown_evidence_status}} =
             SafeRecoveryProfile.run(root: root)
  end

  defp committed_path do
    Application.app_dir(:arbor_commands, "priv/packaging/safe_recovery_profile.v1.json")
  end

  defp committed_bytes, do: File.read!(committed_path())

  defp load_candidate, do: Jason.decode!(committed_bytes())

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-safe-recovery-#{System.unique_integer([:positive, :monotonic])}"
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
