defmodule Arbor.Commands.SafeRecoveryClosure.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryClosure.{Core, Encode}

  @moduletag :fast

  @digest String.duplicate("ab", 32)

  @facility_started [
    "arbor_agent",
    "arbor_llm",
    "os_mon",
    "arbor_sandbox",
    "arbor_shell",
    "postgrex"
  ]

  describe "project/1" do
    test "admits a closed selected payload with bounded shutdown as closed" do
      assert {:ok, evidence} = Core.project(closed_candidate())
      assert evidence["schema"] == Encode.schema()
      assert evidence["version"] == 1
      assert evidence["evidence_status"] == "conformant"
      assert evidence["architecture_status"] == "blocked"
      assert evidence["closure_status"] == "closed"
      assert evidence["findings"] == []

      assert evidence["selected_applications"] == [
               "arbor_kernel",
               "arbor_kernel_runtime",
               "arbor_security",
               "arbor_trust"
             ]

      refute Map.has_key?(evidence, "observations")
      assert {:ok, ^evidence} = Core.project(evidence)
      assert {:ok, digest} = Encode.evidence_digest(evidence)
      assert {:ok, ^digest} = Encode.evidence_digest(evidence)
    end

    test "re-derives findings and ignores injected derived keys" do
      candidate =
        closed_candidate()
        |> put_in(["post_start", "applications"], [
          started("arbor_kernel"),
          started("postgrex")
        ])
        |> Map.update!("artifact_applications", fn apps ->
          [%{"name" => "postgrex", "class" => "third_party"} | apps]
        end)

      assert {:ok, evidence} = Core.project(candidate)
      assert evidence["closure_status"] == "open"
      assert evidence["findings"] != []

      injected =
        evidence
        |> Map.put("closure_status", "closed")
        |> Map.put("findings", [])
        |> Map.put("observations", %{"os_pid" => 1})

      assert {:ok, ^evidence} = Core.project(injected)
    end

    test "drops observations and sorts closed lists" do
      candidate =
        closed_candidate()
        |> Map.put("observations", %{"boot_time_us" => 12, "os_pid" => 99})
        |> Map.update!("selected_applications", &Enum.reverse/1)
        |> Map.update!("artifact_applications", &Enum.reverse/1)

      assert {:ok, evidence} = Core.project(candidate)
      refute Map.has_key?(evidence, "observations")
      assert evidence["selected_applications"] == Enum.sort(candidate["selected_applications"])
    end

    test "reports unexpected first-party, third-party, and forbidden facilities" do
      candidate =
        closed_candidate()
        |> put_in(["post_start", "applications"], [
          started("arbor_kernel"),
          started("arbor_persistence"),
          started("postgrex"),
          started("arbor_shell")
        ])
        |> Map.put("artifact_applications", [
          %{"name" => "arbor_kernel", "class" => "selected_first_party"},
          %{"name" => "arbor_persistence", "class" => "unexpected_first_party"},
          %{"name" => "postgrex", "class" => "third_party"},
          %{"name" => "arbor_shell", "class" => "third_party"}
        ])

      assert {:ok, evidence} = Core.project(candidate)
      assert evidence["closure_status"] == "open"

      ids = Enum.map(evidence["findings"], &{&1["id"], &1["subject"]})

      assert {"unexpected_first_party_started", "arbor_persistence"} in ids
      assert {"third_party_started", "postgrex"} in ids
      assert {"forbidden_facility_present", "postgres_sqlite_and_vector_providers"} in ids
      assert {"forbidden_facility_present", "shell_execution_backends"} in ids
      assert Enum.all?(evidence["findings"], &(&1["owner"] == Encode.finding_owner()))
    end

    test "reports unexplained modules and unbounded shutdown" do
      candidate =
        closed_candidate()
        |> put_in(["post_start", "modules"], [
          %{"module" => "Elixir.Arbor.Kernel", "application" => "arbor_kernel"},
          %{"module" => "Elixir.Mix", "application" => "mix"}
        ])
        |> put_in(["shutdown", "status"], "failed")
        |> put_in(["shutdown", "remaining_names"], ["peer_probe"])

      assert {:ok, evidence} = Core.project(candidate)
      assert evidence["closure_status"] == "open"
      subjects = Enum.map(evidence["findings"], &{&1["id"], &1["subject"]})
      assert {"unexplained_module", "Elixir.Mix"} in subjects
      assert {"unbounded_shutdown", "shutdown"} in subjects
    end

    test "projects every unexplained_module finding above the retired 64 ceiling" do
      candidate = put_in(closed_candidate(), ["post_start", "modules"], unexplained_modules(65))

      assert {:ok, evidence} = Core.project(candidate)
      assert evidence["closure_status"] == "open"
      assert length(evidence["findings"]) == 65

      assert Enum.all?(evidence["findings"], fn finding ->
               finding["id"] == "unexplained_module" and
                 finding["owner"] == Encode.finding_owner()
             end)
    end

    test "projects the independently coexisting finding-category maximum" do
      assert {:ok, evidence} = Core.project(maximal_finding_candidate())
      assert evidence["closure_status"] == "open"
      assert length(evidence["findings"]) == Encode.max_findings()
      assert :ok = Encode.validate_evidence(evidence)

      by_id = Enum.group_by(evidence["findings"], & &1["id"])
      assert length(by_id["third_party_started"]) == 128
      assert length(by_id["forbidden_facility_present"]) == 6
      assert length(by_id["unexplained_module"]) == 4_096
      assert length(by_id["unbounded_shutdown"]) == 1
      assert length(by_id["selected_start_failed"]) == 128
    end

    test "reports selected applications that did not start" do
      candidate = closed_candidate()
      assert {:ok, evidence} = Core.project(candidate)
      subjects = Enum.map(evidence["findings"], &{&1["id"], &1["subject"]})
      refute {"selected_start_failed", "arbor_kernel"} in subjects

      unstarted = put_in(candidate, ["post_start", "applications"], [])
      assert {:ok, open} = Core.project(unstarted)
      ids = Enum.map(open["findings"], &{&1["id"], &1["subject"]})
      assert {"selected_start_failed", "arbor_security"} in ids
      assert open["closure_status"] == "open"
    end

    test "rejects extra, missing, and unknown fields" do
      assert {:error, :closed_keys} = Core.project(Map.put(closed_candidate(), "hook", true))
      assert {:error, :closed_keys} = Core.project(Map.delete(closed_candidate(), "shutdown"))
      assert {:error, :invalid_candidate} = Core.project(:nope)
    end

    test "rejects schema mismatch and malformed nested snapshots" do
      assert {:error, :exact_mismatch} =
               Core.project(Map.put(closed_candidate(), "schema", "arbor.packaging.other.v1"))

      assert {:error, {:invalid_field, "post_start", :invalid_snapshot}} =
               Core.project(put_in(closed_candidate(), ["post_start"], "nope"))

      assert {:error, {:invalid_field, "artifact_applications", :duplicate}} =
               Core.project(
                 Map.update!(closed_candidate(), "artifact_applications", fn [app | rest] ->
                   [app, app | rest]
                 end)
               )
    end
  end

  defp closed_candidate do
    %{
      "schema" => Encode.schema(),
      "version" => 1,
      "profile" => %{"name" => "safe_recovery", "digest" => @digest},
      "artifact" => %{"payload_tree_digest" => @digest},
      "selected_applications" => [
        "arbor_trust",
        "arbor_security",
        "arbor_kernel_runtime",
        "arbor_kernel"
      ],
      "artifact_applications" => [
        %{"name" => "arbor_trust", "class" => "selected_first_party"},
        %{"name" => "arbor_security", "class" => "selected_first_party"},
        %{"name" => "arbor_kernel_runtime", "class" => "selected_first_party"},
        %{"name" => "arbor_kernel", "class" => "selected_first_party"},
        %{"name" => "kernel", "class" => "runtime"},
        %{"name" => "elixir", "class" => "runtime"}
      ],
      "pre_start" => snapshot([]),
      "post_start" =>
        snapshot(
          [
            started("arbor_kernel"),
            started("arbor_kernel_runtime"),
            started("arbor_security"),
            started("arbor_trust"),
            started("kernel")
          ],
          modules: [
            %{"module" => "Elixir.Arbor.Kernel", "application" => "arbor_kernel"},
            %{"module" => "Elixir.Kernel", "application" => "elixir"}
          ]
        ),
      "shutdown" => %{"status" => "bounded", "remaining_names" => []}
    }
  end

  defp snapshot(applications, opts \\ []) do
    %{
      "applications" => applications,
      "modules" => Keyword.get(opts, :modules, []),
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

  defp started(name), do: %{"name" => name, "state" => "started"}

  defp unexplained_modules(count) do
    for i <- 1..count do
      %{"module" => "Elixir.Unexplained#{i}", "application" => "mix"}
    end
  end

  defp maximal_finding_candidate do
    selected = for i <- 1..128, do: padded("sel", i)
    extra_started = for i <- 1..122, do: padded("tp", i)
    started_names = @facility_started ++ extra_started

    artifact_applications =
      Enum.map(started_names, fn name ->
        %{"name" => name, "class" => "third_party"}
      end)

    closed_candidate()
    |> Map.put("selected_applications", selected)
    |> Map.put("artifact_applications", artifact_applications)
    |> put_in(["post_start", "applications"], Enum.map(started_names, &started/1))
    |> put_in(["post_start", "modules"], unexplained_modules(4_096))
    |> put_in(["shutdown", "status"], "failed")
    |> put_in(["shutdown", "remaining_names"], [])
  end

  defp padded(prefix, i) do
    prefix <> "_" <> String.pad_leading(Integer.to_string(i), 3, "0")
  end
end
