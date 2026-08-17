defmodule Arbor.Commands.SafeRecoveryClosureFacadeTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryClosure
  alias Arbor.Commands.SafeRecoveryClosure.{Core, Encode}
  alias Arbor.Common.SafePath

  @moduletag :fast

  setup do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "production rejects caller-selected execution seams" do
    forbidden = [
      run_peer: fn -> {:ok, %{}} end,
      evidence: %{},
      release_root: "/tmp/rel",
      selected: ["arbor_kernel"],
      cookie: "secret",
      mfa: {__MODULE__, :measure, []},
      executable: "/bin/true",
      code_path: "."
    ]

    for {key, value} <- forbidden do
      assert {:error, {:production_opts_forbid_synthetic, [^key]}} =
               SafeRecoveryClosure.report([{key, value}])

      assert {:error, {:production_opts_forbid_synthetic, [^key]}} =
               SafeRecoveryClosure.measure([{key, value}])
    end
  end

  test "report and check fail closed when committed evidence is absent", %{root: root} do
    assert {:error, :evidence_missing} = SafeRecoveryClosure.report(root: root)
    assert {:error, :evidence_missing} = SafeRecoveryClosure.check(root: root)
  end

  test "production measure and write reject a caller-selected destination" do
    assert {:error, {:production_opts_forbid_synthetic, [:release_root]}} =
             SafeRecoveryClosure.measure(release_root: "/tmp/rel")

    assert {:error, {:production_opts_forbid_synthetic, [:release_root]}} =
             SafeRecoveryClosure.write(release_root: "/tmp/rel")
  end

  test "report admits projected evidence and check requires a closed set", %{root: root} do
    {:ok, evidence} = Core.project(closed_candidate())
    write_evidence!(root, evidence)

    assert {:ok, report} = SafeRecoveryClosure.report(root: root)
    assert report["mode"] == "report"
    assert report["closure_status"] == "closed"
    assert report["findings_count"] == 0
    assert report["architecture_status"] == "blocked"
    assert {:ok, ^evidence} = Core.project(report["evidence"])

    assert {:ok, check} = SafeRecoveryClosure.check(root: root, json: true)
    assert check["mode"] == "check"
    assert check["output"] == "json"
    assert check["evidence_digest"] == report["evidence_digest"]
  end

  test "check admits reviewed blocked-open evidence", %{root: root} do
    candidate =
      closed_candidate()
      |> put_in(["post_start", "applications"], [
        %{"name" => "arbor_kernel", "state" => "started"},
        %{"name" => "postgrex", "state" => "started"}
      ])
      |> Map.update!("artifact_applications", fn apps ->
        [%{"name" => "postgrex", "class" => "third_party"} | apps]
      end)

    {:ok, evidence} = Core.project(candidate)
    write_evidence!(root, evidence)

    assert evidence["closure_status"] == "open"
    assert {:ok, report} = SafeRecoveryClosure.report(root: root)
    assert report["closure_status"] == "open"
    assert {:ok, check} = SafeRecoveryClosure.check(root: root)
    assert check["closure_status"] == "open"
    assert check["findings_count"] > 0
  end

  test "write_from_evidence_for_test publishes the committed path", %{root: root} do
    {:ok, evidence} = Core.project(closed_candidate())

    assert {:ok, result} =
             SafeRecoveryClosure.write_from_evidence_for_test(evidence, root: root)

    assert result["mode"] == "write"
    path = Path.join(root, SafeRecoveryClosure.default_evidence_path())
    assert File.regular?(path)
    assert {:ok, check} = SafeRecoveryClosure.check(root: root)
    assert check["evidence_digest"] == result["evidence_digest"]
  end

  test "measure_for_test projects an injected peer sample", %{root: root} do
    install_committed_artifact!(root)
    {:ok, closed} = Core.project(closed_candidate())

    assert {:ok, result} =
             SafeRecoveryClosure.run_for_test(
               mode: :measure,
               root: root,
               run_peer: fn ->
                 {:ok,
                  %{
                    "pre_start" => closed["pre_start"],
                    "post_start" => closed["post_start"],
                    "shutdown" => closed["shutdown"],
                    "observations" => %{"os_pid" => 9, "boot_time_us" => 1, "cookie_set" => true}
                  }}
               end
             )

    assert result["mode"] == "measure"
    refute Map.has_key?(result["evidence"], "observations")
    assert result["evidence"]["closure_status"] == "closed"
    refute inspect(result) =~ "RELEASE_COOKIE"
  end

  defp closed_candidate do
    digest = String.duplicate("ab", 32)

    %{
      "schema" => Encode.schema(),
      "version" => 1,
      "profile" => %{"name" => "safe_recovery", "digest" => digest},
      "artifact" => %{"payload_tree_digest" => digest},
      "selected_applications" => [
        "arbor_kernel",
        "arbor_kernel_runtime",
        "arbor_security",
        "arbor_trust"
      ],
      "artifact_applications" => [
        %{"name" => "arbor_kernel", "class" => "selected_first_party"},
        %{"name" => "arbor_kernel_runtime", "class" => "selected_first_party"},
        %{"name" => "arbor_security", "class" => "selected_first_party"},
        %{"name" => "arbor_trust", "class" => "selected_first_party"},
        %{"name" => "kernel", "class" => "runtime"}
      ],
      "pre_start" => empty_snapshot(),
      "post_start" =>
        empty_snapshot()
        |> Map.put("applications", [
          %{"name" => "arbor_kernel", "state" => "started"},
          %{"name" => "arbor_kernel_runtime", "state" => "started"},
          %{"name" => "arbor_security", "state" => "started"},
          %{"name" => "arbor_trust", "state" => "started"}
        ]),
      "shutdown" => %{"status" => "bounded", "remaining_names" => []}
    }
  end

  defp empty_snapshot do
    %{
      "applications" => [],
      "modules" => [],
      "registered_names" => [],
      "supervisors" => [],
      "ets_tables" => [],
      "ports" => [],
      "nifs" => [],
      "logger_handlers" => [],
      "telemetry_handlers" => [],
      "listeners" => []
    }
  end

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-e0b3-#{System.unique_integer([:positive, :monotonic])}"
      )

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"] do
      path = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# marker\n")
    end

    {:ok, real} = SafePath.resolve_real(root)
    real
  end

  defp write_evidence!(root, evidence) do
    {:ok, bytes} = Encode.canonical_json(evidence)
    path = Path.join(root, SafeRecoveryClosure.default_evidence_path())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp install_committed_artifact!(root) do
    src = Application.app_dir(:arbor_commands, "priv/packaging")
    dest = Path.join(root, "apps/arbor_commands/priv/packaging")
    File.mkdir_p!(dest)

    for name <- [
          "safe_recovery_artifact.v1.json",
          "safe_recovery_artifact.payload.v1.json"
        ] do
      File.cp!(Path.join(src, name), Path.join(dest, name))
    end
  end
end
