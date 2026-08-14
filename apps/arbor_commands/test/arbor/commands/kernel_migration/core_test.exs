defmodule Arbor.Commands.KernelMigration.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.KernelMigration.{Core, Encode, Evidence}

  @moduletag :fast

  defp oid(tag) when is_binary(tag) do
    :crypto.hash(:sha256, tag)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 40)
  end

  defp edge(overrides) do
    Map.merge(
      %{
        "file" => "apps/arbor_common/lib/foo.ex",
        "line" => 10,
        "from_module" => "Arbor.Common.Foo",
        "target" => "Arbor.Actions",
        "kind" => "expr",
        "class" => "code",
        "from_app" => "arbor_common",
        "to_app" => "arbor_actions",
        "from_band" => "K",
        "to_band" => "C",
        "band_pair" => "K->C",
        "fate" => "upward",
        "level_direction" => "level_upward",
        "declared" => false,
        "extract_seq" => 1
      },
      overrides
    )
  end

  defp census(edges) do
    %{
      "classified_edges" => edges,
      "provenance" => %{
        "scan_manifest_digest" => String.duplicate("a", 64),
        "tree_oid" => String.duplicate("b", 40),
        "object_format" => "sha1",
        "provenance_source" => "test_injection"
      }
    }
  end

  defp reviewed_disposition(finding, overrides \\ %{}) do
    Map.merge(
      %{
        "file" => finding["file"],
        "from_module" => finding["from_module"],
        "target" => finding["target"],
        "kind" => finding["kind"],
        "class" => finding["class"],
        "occurrence_ordinal" => finding["occurrence_ordinal"],
        "disposition" => "invert_consumer_behaviour",
        "owner_packet" => "K1C-common-action-security-plumbing",
        "rationale" => "Actions URI port must invert to a contracts behaviour.",
        "blob_oid" => oid("disp")
      },
      overrides
    )
  end

  test "mix_task_path? is segment-aware" do
    assert Core.mix_task_path?("apps/arbor_common/lib/mix/tasks/arbor/doctor.ex")
    refute Core.mix_task_path?("apps/arbor_common/lib/arbor/common/foo.ex")
    refute Core.mix_task_path?("apps/arbor_common/lib/mix/not_tasks/x.ex")
  end

  test "duplicate identical sites get distinct ordinals; line-only moves preserve ids" do
    first = edge(%{"line" => 10, "extract_seq" => 1})
    second = edge(%{"line" => 20, "extract_seq" => 2})
    {:ok, projected} = Core.project(census([first, second]))
    [a, b] = projected["runtime"]
    assert a["occurrence_ordinal"] == 1
    assert b["occurrence_ordinal"] == 2
    assert a["finding_id"] != b["finding_id"]

    moved = [
      edge(%{"line" => 110, "extract_seq" => 1}),
      edge(%{"line" => 120, "extract_seq" => 2})
    ]

    {:ok, moved_proj} = Core.project(census(moved))

    assert Enum.map(moved_proj["runtime"], & &1["finding_id"]) ==
             Enum.map(projected["runtime"], & &1["finding_id"])
  end

  test "runtime vs mix_task split by path only" do
    edges = [
      edge(%{"file" => "apps/arbor_common/lib/foo.ex"}),
      edge(%{
        "file" => "apps/arbor_common/lib/mix/tasks/arbor/doctor.ex",
        "from_module" => "Mix.Tasks.Arbor.Doctor",
        "line" => 4
      })
    ]

    {:ok, projected} = Core.project(census(edges))
    assert length(projected["runtime"]) == 1
    assert length(projected["mix_task"]) == 1
    assert hd(projected["mix_task"])["collection"] == "mix_task"
  end

  test "intra-K and non-upward edges are not projected" do
    edges = [
      edge(%{"fate" => "intra_band", "to_app" => "arbor_contracts", "to_band" => "K"}),
      edge(%{"from_app" => "arbor_actions", "from_band" => "C"})
    ]

    {:ok, projected} = Core.project(census(edges))
    assert projected["runtime"] == []
    assert projected["mix_task"] == []
  end

  test "identity ignores tree_oid" do
    a =
      Encode.identity(%{
        "scan_manifest_digest" => "aa",
        "disposition_manifest_digest" => "bb",
        "boundary_manifest_digest" => "cc",
        "formatter_manifest_digest" => "dd",
        "policy_version" => "k0.v1",
        "k_apps" => Core.k_apps(),
        "runtime_digest" => "ee",
        "mix_task_digest" => "ff"
      })

    b =
      Encode.identity(%{
        "scan_manifest_digest" => "aa",
        "disposition_manifest_digest" => "bb",
        "boundary_manifest_digest" => "cc",
        "formatter_manifest_digest" => "dd",
        "policy_version" => "k0.v1",
        "k_apps" => Core.k_apps(),
        "runtime_digest" => "ee",
        "mix_task_digest" => "ff",
        "tree_oid" => String.duplicate("f", 40)
      })

    assert a == b
  end

  test "normative report bytes ignore volatile HEAD tree identity" do
    {:ok, projected} = Core.project(census([edge(%{})]))

    comparison = %{
      "status" => "ok",
      "failures" => [],
      "failure_count" => 0,
      "truncated" => false
    }

    report = Core.show(projected, comparison, %{})

    moved_head =
      put_in(
        projected,
        ["provenance", "tree_oid"],
        String.duplicate("f", 40)
      )

    moved_report = Core.show(moved_head, comparison, %{})

    refute Map.has_key?(report["provenance"], "tree_oid")
    assert {:ok, bytes} = Encode.encode_report(report)
    assert {:ok, ^bytes} = Encode.encode_report(moved_report)
  end

  test "canonical finding key order is stable at the byte representation boundary" do
    {:ok, projected} = Core.project(census([edge(%{})]))
    finding = hd(projected["runtime"])

    assert {:ok, bytes} = Encode.encode_ordered_map(finding, Encode.finding_key_order())

    keys =
      ~r/"([^"]+)":/
      |> Regex.scan(bytes)
      |> Enum.map(fn [_, key] -> key end)

    assert keys == Encode.finding_key_order()
  end

  test "nested canonical report key order is stable at the byte boundary" do
    {:ok, projected} = Core.project(census([edge(%{})]))

    report =
      Core.show(projected, %{"status" => "ok", "failures" => [], "failure_count" => 0}, %{
        "mode" => "check",
        "output" => "human"
      })

    assert {:ok, bytes} = Encode.encode_report(report)
    assert {:ok, again} = Encode.encode_report(Map.put(report, "output", "json"))
    assert bytes == again
    refute String.contains?(bytes, "\"mode\"")
    refute String.contains?(bytes, "\"output\"")

    expected_prefix =
      "{\"schema\":\"arbor.packaging.kernel_migration.report.v1\",\"status\":\"ok\",\"identity\":"

    assert String.starts_with?(bytes, expected_prefix)
    assert String.contains?(bytes, "\"policy\":{\"version\":\"k0.v1\",\"k_apps\":")
    assert String.contains?(bytes, "\"counts\":{\"total\":")
  end

  test "digests are order-independent and domain-separated" do
    a = [
      %{"current_path" => "b.ex", "blob_oid" => oid("b")},
      %{"current_path" => "a.ex", "blob_oid" => oid("a")}
    ]

    b = Enum.reverse(a)
    assert Encode.formatter_files_digest(a) == Encode.formatter_files_digest(b)
    assert Encode.boundary_digest(a) != Encode.formatter_files_digest(a)
    assert Encode.runtime_digest(a) != Encode.mix_task_digest(a)
    assert Encode.disposition_digest(a) != Encode.boundary_digest(a)
  end

  test "missing duplicate stale extra dispositions fail closed; allow-list rejected" do
    {:ok, projected} = Core.project(census([edge(%{})]))
    finding = hd(projected["runtime"])

    good = %{
      "schema" => "arbor.packaging.kernel_migration.disposition.v1",
      "version" => 1,
      "entries" => [reviewed_disposition(finding)]
    }

    assert {:ok, admitted} = Core.admit_dispositions(good)

    assert {:ok, %{"status" => "ok", "failure_count" => 0}} =
             Core.compare_dispositions(projected["runtime"], admitted)

    assert {:error, :invalid_disposition} =
             Core.admit_dispositions(%{
               good
               | "entries" => [Map.put(hd(good["entries"]), "disposition", "accepted")]
             })

    assert {:error, :missing_disposition_evidence} =
             Core.admit_dispositions(%{
               good
               | "entries" => [Map.delete(hd(good["entries"]), "blob_oid")]
             })

    assert {:ok, %{"status" => "failed"} = missing} =
             Core.compare_dispositions(projected["runtime"], %{admitted | "entries" => []})

    assert Enum.any?(missing["failures"], &(&1["reason"] == "missing_disposition"))

    extra_entry =
      finding
      |> Map.put("target", "Arbor.AI")
      |> Map.put("finding_id", nil)
      |> reviewed_disposition(%{
        "target" => "Arbor.AI",
        "disposition" => "remove_dead_code",
        "rationale" => "stale extra"
      })

    {:ok, with_extra} =
      Core.admit_dispositions(%{good | "entries" => good["entries"] ++ [extra_entry]})

    assert {:ok, %{"status" => "failed"} = extra} =
             Core.compare_dispositions(projected["runtime"], with_extra)

    assert Enum.any?(extra["failures"], &(&1["reason"] == "stale_or_extra_disposition"))

    dup = %{good | "entries" => good["entries"] ++ good["entries"]}
    assert {:error, :duplicate_disposition} = Core.admit_dispositions(dup)
  end

  test "duplicate occurrence ids are rejected at disposition admission" do
    {:ok, projected} =
      Core.project(census([edge(%{}), edge(%{"line" => 20, "extract_seq" => 2})]))

    [first, second] = projected["runtime"]

    dup_ids = %{
      "schema" => "arbor.packaging.kernel_migration.disposition.v1",
      "version" => 1,
      "entries" => [
        reviewed_disposition(first),
        reviewed_disposition(second, %{"occurrence_ordinal" => first["occurrence_ordinal"]})
        |> Map.put("file", first["file"])
        |> Map.put("from_module", first["from_module"])
        |> Map.put("target", first["target"])
        |> Map.put("kind", first["kind"])
        |> Map.put("class", first["class"])
      ]
    }

    assert {:error, :duplicate_disposition} = Core.admit_dispositions(dup_ids)
  end

  test "boundary rejects omitted evidence, Character, wrong kind/line, and extras" do
    runtime = [
      edge(%{
        "file" => "apps/arbor_common/lib/arbor/common/skill_importer.ex",
        "from_module" => "Arbor.Common.SkillImporter",
        "target" => "Arbor.Security.Reflex",
        "kind" => "expr",
        "line" => 170
      })
    ]

    {:ok, projected} = Core.project(census(runtime))
    finding = hd(projected["runtime"])
    path = finding["file"]

    good_entry = %{
      "current_path" => path,
      "from_module" => finding["from_module"],
      "target" => finding["target"],
      "kind" => finding["kind"],
      "site_line" => finding["line"],
      "proof_destination" => "apps/arbor_kernel/lib/arbor/common/skill_importer.ex",
      "source" => "census_runtime",
      "blob_oid" => oid("bound")
    }

    assert {:error, :missing_boundary_evidence} =
             Evidence.admit_boundary(%{
               "schema" => "arbor.packaging.kernel_migration.boundary.v1",
               "version" => 1,
               "entries" => [Map.delete(good_entry, "blob_oid")]
             })

    assert {:error, :missing_boundary_evidence} =
             Evidence.admit_boundary(%{
               "schema" => "arbor.packaging.kernel_migration.boundary.v1",
               "version" => 1,
               "entries" => [Map.delete(good_entry, "site_line")]
             })

    character = %{
      "schema" => "arbor.packaging.kernel_migration.boundary.v1",
      "version" => 1,
      "entries" => [
        %{
          "current_path" => "apps/arbor_contracts/lib/arbor/contracts/agent/spec.ex",
          "from_module" => "Arbor.Contracts.Agent.Spec",
          "target" => "Arbor.Agent.Character",
          "kind" => "alias",
          "site_line" => 21,
          "proof_destination" => "apps/arbor_kernel/lib/arbor/contracts/agent/spec.ex",
          "source" => "census_runtime",
          "blob_oid" => oid("char")
        }
      ]
    }

    assert {:ok, admitted_char} = Evidence.admit_boundary(character)

    assert {:ok, %{"status" => "failed"} = cmp} =
             Evidence.compare_boundary(admitted_char, projected["runtime"], %{})

    assert Enum.any?(cmp["failures"], &(&1["reason"] == "boundary_excluded_character"))
    assert Enum.any?(cmp["failures"], &(&1["reason"] == "boundary_count"))

    stale_line = %{
      "schema" => "arbor.packaging.kernel_migration.boundary.v1",
      "version" => 1,
      "entries" => [Map.put(good_entry, "site_line", 999)]
    }

    assert {:ok, admitted_stale} = Evidence.admit_boundary(stale_line)

    assert {:ok, %{"status" => "failed"} = stale_cmp} =
             Evidence.compare_boundary(admitted_stale, projected["runtime"], %{})

    assert Enum.any?(stale_cmp["failures"], &(&1["reason"] == "boundary_site_mismatch"))
    assert Enum.any?(stale_cmp["failures"], &(&1["reason"] == "boundary_extra_or_stale"))

    wrong_kind = %{
      "schema" => "arbor.packaging.kernel_migration.boundary.v1",
      "version" => 1,
      "entries" => [Map.put(good_entry, "kind", "alias")]
    }

    assert {:ok, admitted_kind} = Evidence.admit_boundary(wrong_kind)

    assert {:ok, %{"status" => "failed"} = kind_cmp} =
             Evidence.compare_boundary(admitted_kind, projected["runtime"], %{})

    assert Enum.any?(kind_cmp["failures"], &(&1["reason"] == "boundary_site_mismatch"))
  end

  test "boundary requires exact 20 runtime-minus-Character plus two external identities" do
    runtime_edges =
      for i <- 1..20 do
        edge(%{
          "file" => "apps/arbor_common/lib/f#{i}.ex",
          "from_module" => "Arbor.Common.F#{i}",
          "target" => "Arbor.Actions",
          "kind" => "expr",
          "line" => i,
          "extract_seq" => i
        })
      end

    character_edges = [
      edge(%{
        "file" => "apps/arbor_contracts/lib/arbor/contracts/agent/spec.ex",
        "from_module" => "Arbor.Contracts.Agent.Spec",
        "target" => "Arbor.Agent.Character",
        "kind" => "alias",
        "line" => 21,
        "extract_seq" => 100
      }),
      edge(%{
        "file" => "apps/arbor_contracts/lib/arbor/contracts/agent/spec.ex",
        "from_module" => "Arbor.Contracts.Agent.Spec",
        "target" => "Arbor.Agent.Character",
        "kind" => "typespec",
        "class" => "typespec_only",
        "line" => 27,
        "extract_seq" => 101
      })
    ]

    {:ok, projected} = Core.project(census(runtime_edges ++ character_edges))
    assert length(projected["runtime"]) == 22

    runtime_entries =
      projected["runtime"]
      |> Enum.reject(&(&1["target"] == "Arbor.Agent.Character"))
      |> Enum.map(fn finding ->
        %{
          "current_path" => finding["file"],
          "from_module" => finding["from_module"],
          "target" => finding["target"],
          "kind" => finding["kind"],
          "site_line" => finding["line"],
          "proof_destination" => "apps/arbor_kernel/lib/#{Path.basename(finding["file"])}",
          "source" => "census_runtime",
          "blob_oid" => oid("rt")
        }
      end)

    externals = [
      %{
        "current_path" => "apps/arbor_common/lib/arbor/common/model_profile.ex",
        "from_module" => "Arbor.Common.ModelProfile",
        "target" => "LLMDB",
        "kind" => "attribute",
        "site_line" => 344,
        "proof_destination" => "apps/arbor_kernel/lib/arbor/common/model_profile.ex",
        "source" => "census_ignored_external",
        "blob_oid" => oid("llmdb")
      },
      %{
        "current_path" => "apps/arbor_common/lib/arbor/common/agent_telemetry/store.ex",
        "from_module" => "Arbor.Common.AgentTelemetry.Store",
        "target" => "Ecto.Adapters.Postgres",
        "kind" => "expr",
        "site_line" => 323,
        "proof_destination" => "apps/arbor_kernel/lib/arbor/common/agent_telemetry/store.ex",
        "source" => "census_ignored_external",
        "blob_oid" => oid("pg")
      }
    ]

    raw = %{
      "schema" => "arbor.packaging.kernel_migration.boundary.v1",
      "version" => 1,
      "entries" => runtime_entries ++ externals
    }

    assert {:ok, admitted} = Evidence.admit_boundary(raw)

    root = find_umbrella_root(__DIR__)

    blobs =
      Map.new(admitted["entries"], fn entry ->
        bytes =
          if entry["source"] == "census_ignored_external" do
            File.read!(Path.join(root, entry["current_path"]))
          else
            ""
          end

        {entry["current_path"], %{blob_oid: entry["blob_oid"], bytes: bytes}}
      end)

    assert {:ok, %{"status" => "ok", "failure_count" => 0}} =
             Evidence.compare_boundary(admitted, projected["runtime"], blobs)

    substituted = %{
      raw
      | "entries" =>
          List.replace_at(externals, 0, %{
            hd(externals)
            | "from_module" => "Arbor.Common.ModelProfile",
              "target" => "SomeOtherDB"
          }) ++ runtime_entries
    }

    assert {:ok, admitted_sub} = Evidence.admit_boundary(substituted)

    assert {:ok, %{"status" => "failed"} = sub_cmp} =
             Evidence.compare_boundary(admitted_sub, projected["runtime"], blobs)

    assert Enum.any?(sub_cmp["failures"], &(&1["reason"] == "boundary_external_unexpected"))
    assert Enum.any?(sub_cmp["failures"], &(&1["reason"] == "boundary_external_missing"))

    wrong_line = %{
      raw
      | "entries" =>
          runtime_entries ++
            [
              hd(externals),
              Map.put(List.last(externals), "site_line", 1)
            ]
    }

    assert {:ok, admitted_line} = Evidence.admit_boundary(wrong_line)

    assert {:ok, %{"status" => "failed"} = line_cmp} =
             Evidence.compare_boundary(admitted_line, projected["runtime"], blobs)

    assert Enum.any?(line_cmp["failures"], &(&1["reason"] == "boundary_external_missing"))
  end

  test "external AstExtract matches complete site fields, not target anywhere" do
    root = find_umbrella_root(__DIR__)

    profile_path = "apps/arbor_common/lib/arbor/common/model_profile.ex"
    store_path = "apps/arbor_common/lib/arbor/common/agent_telemetry/store.ex"
    profile = File.read!(Path.join(root, profile_path))
    store = File.read!(Path.join(root, store_path))

    llmdb = %{
      "current_path" => profile_path,
      "from_module" => "Arbor.Common.ModelProfile",
      "target" => "LLMDB",
      "kind" => "attribute",
      "site_line" => 344,
      "proof_destination" => "apps/arbor_kernel/lib/arbor/common/model_profile.ex"
    }

    postgres = %{
      "current_path" => store_path,
      "from_module" => "Arbor.Common.AgentTelemetry.Store",
      "target" => "Ecto.Adapters.Postgres",
      "kind" => "expr",
      "site_line" => 323,
      "proof_destination" => "apps/arbor_kernel/lib/arbor/common/agent_telemetry/store.ex"
    }

    assert Evidence.extract_matches_site?(profile, llmdb)
    assert Evidence.extract_matches_site?(store, postgres)
    refute Evidence.extract_matches_site?(profile, Map.put(llmdb, "site_line", 1))
    refute Evidence.extract_matches_site?(store, Map.put(postgres, "site_line", 404))
    refute Evidence.extract_matches_site?(store, Map.put(postgres, "target", "LLMDB"))
    refute Evidence.extract_matches_site?(profile, Map.put(llmdb, "kind", "expr"))
    refute Evidence.extract_matches_site?(profile, Map.put(llmdb, "from_module", "Arbor.Common"))

    llmdb_entry =
      Map.merge(llmdb, %{
        "source" => "census_ignored_external",
        "blob_oid" => oid("llmdb")
      })

    postgres_entry =
      Map.merge(postgres, %{
        "source" => "census_ignored_external",
        "blob_oid" => oid("pg")
      })

    assert {:ok, admitted} =
             Evidence.admit_boundary(%{
               "schema" => "arbor.packaging.kernel_migration.boundary.v1",
               "version" => 1,
               "entries" => [llmdb_entry, postgres_entry]
             })

    good_blobs = %{
      profile_path => %{blob_oid: oid("llmdb"), bytes: profile},
      store_path => %{blob_oid: oid("pg"), bytes: store}
    }

    assert {:ok, good_cmp} = Evidence.compare_boundary(admitted, [], good_blobs)
    refute Enum.any?(good_cmp["failures"], &(&1["reason"] == "boundary_external_site"))
    refute Enum.any?(good_cmp["failures"], &(&1["reason"] == "boundary_external_blob"))

    missing_profile = %{
      good_blobs
      | profile_path => %{
          blob_oid: oid("llmdb"),
          bytes: "defmodule Arbor.Common.ModelProfile, do: :ok\n"
        }
    }

    assert {:ok, %{"status" => "failed"} = profile_cmp} =
             Evidence.compare_boundary(admitted, [], missing_profile)

    assert Enum.any?(profile_cmp["failures"], fn failure ->
             failure["reason"] == "boundary_external_site" and
               String.starts_with?(failure["detail"], profile_path)
           end)

    missing_store = %{
      good_blobs
      | store_path => %{
          blob_oid: oid("pg"),
          bytes: "defmodule Arbor.Common.AgentTelemetry.Store, do: :ok\n"
        }
    }

    assert {:ok, %{"status" => "failed"} = store_cmp} =
             Evidence.compare_boundary(admitted, [], missing_store)

    assert Enum.any?(store_cmp["failures"], fn failure ->
             failure["reason"] == "boundary_external_site" and
               String.starts_with?(failure["detail"], store_path)
           end)
  end

  defp find_umbrella_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "umbrella root not found"
      true -> find_umbrella_root(Path.dirname(dir))
    end
  end

  test "formatter requires kernel destinations, exact file count, and rejects unexpected absent configs" do
    raw = %{
      "schema" => "arbor.packaging.kernel_migration.formatter.v1",
      "version" => 1,
      "files" => [
        %{
          "current_path" => "apps/arbor_monitor/lib/arbor/monitor/anomaly_forwarder.ex",
          "proof_destination" => "apps/arbor_kernel/lib/arbor/monitor/anomaly_forwarder.ex",
          "blob_oid" => oid("fmt")
        }
      ],
      "configs" => [
        %{"path" => ".formatter.exs", "status" => "present", "blob_oid" => oid("cfg")},
        %{"path" => "apps/arbor_contracts/.formatter.exs", "status" => "expected_absent"}
      ]
    }

    assert {:error, :missing_formatter_evidence} =
             Evidence.admit_formatter(%{
               raw
               | "files" => [Map.delete(hd(raw["files"]), "blob_oid")]
             })

    assert {:ok, admitted} = Evidence.admit_formatter(raw)

    assert {:ok, %{"status" => "failed"} = cmp} =
             Evidence.compare_formatter(admitted, %{
               "apps/arbor_monitor/lib/arbor/monitor/anomaly_forwarder.ex" => %{
                 blob_oid: oid("fmt")
               },
               ".formatter.exs" => %{blob_oid: oid("cfg")},
               "apps/arbor_contracts/.formatter.exs" => %{blob_oid: oid("surprise")}
             })

    assert Enum.any?(cmp["failures"], &(&1["reason"] == "formatter_count"))
    assert Enum.any?(cmp["failures"], &(&1["reason"] == "formatter_config_unexpected"))
  end

  test "report show is non-self-referential and bounded" do
    {:ok, projected} = Core.project(census([edge(%{})]))

    report =
      Core.show(projected, %{"status" => "ok", "failures" => [], "failure_count" => 0}, %{
        "mode" => "report",
        "output" => "json"
      })

    assert report["schema"] == "arbor.packaging.kernel_migration.report.v1"
    refute Map.has_key?(report["provenance"], "report_path")
    refute Map.has_key?(report["provenance"], "tree_oid")
    assert is_binary(report["identity"])
    assert byte_size(report["identity"]) == 64
  end
end
