defmodule Arbor.Commands.PlatformInventory.EncodeTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.PlatformInventory.Core
  alias Arbor.Commands.PlatformInventory.Encode

  @moduletag :fast

  @oid String.duplicate("a", 40)

  describe "entries_digest/1" do
    test "digests a valid entry deterministically" do
      entry = valid_entry()

      assert {:ok, digest} = Encode.entries_digest([entry])
      assert {:ok, ^digest} = Encode.entries_digest([entry])
      assert byte_size(digest) == 64
    end

    test "digest is independent of input list order" do
      a = valid_entry(path: "apps/arbor_shell/lib/a.ex")
      b = valid_entry(path: "apps/arbor_shell/lib/b.ex")

      assert {:ok, d1} = Encode.entries_digest([a, b])
      assert {:ok, d2} = Encode.entries_digest([b, a])
      assert d1 == d2
    end

    test "rejects a missing field instead of defaulting it" do
      entry = Map.delete(valid_entry(), "modules")

      assert {:error, {:field_mismatch, %{missing: ["modules"]}}} = Encode.entries_digest([entry])
    end

    test "rejects an extra field" do
      entry = Map.put(valid_entry(), "unexpected", true)

      assert {:error, {:field_mismatch, %{extra: ["unexpected"]}}} =
               Encode.entries_digest([entry])
    end

    test "rejects duplicate paths across the list" do
      entry = valid_entry()

      assert {:error, :duplicate_entries} = Encode.entries_digest([entry, entry])
    end

    test "rejects a malformed blob_oid" do
      entry = Map.put(valid_entry(), "blob_oid", "not-an-oid")

      assert {:error, {:invalid_field, "blob_oid", :invalid_oid}} = Encode.entries_digest([entry])
    end

    test "rejects an unbounded byte_size" do
      entry = Map.put(valid_entry(), "byte_size", 999_999_999)

      assert {:error, {:invalid_field, "byte_size", :unbounded}} = Encode.entries_digest([entry])
    end

    test "rejects a non-boolean value in a boolean field instead of coercing it" do
      entry = Map.put(valid_entry(), "telemetry", 1)

      assert {:error, {:invalid_field, "telemetry", :not_a_boolean}} =
               Encode.entries_digest([entry])

      entry2 = Map.put(valid_entry(), "telemetry", "true")

      assert {:error, {:invalid_field, "telemetry", :not_a_boolean}} =
               Encode.entries_digest([entry2])
    end

    test "rejects an app outside the closed nine-app set" do
      entry = Map.put(valid_entry(), "app", "arbor_dashboard")

      assert {:error, {:invalid_field, "app", :unknown_app}} = Encode.entries_digest([entry])
    end

    test "rejects a non-JSON-safe value instead of falling back to inspect/1" do
      entry = Map.put(valid_entry(), "path", self())

      assert {:error, {:invalid_field, "path", :not_a_string}} = Encode.entries_digest([entry])
    end

    test "rejects mixed atom/string keys, structs, and atoms" do
      mixed =
        valid_entry()
        |> Map.delete("path")
        |> Map.put(:path, "apps/arbor_shell/lib/example.ex")

      assert {:error, :non_string_keys} = Encode.entries_digest([mixed])
      assert {:error, :invalid_entries} = Encode.entries_digest([Date.utc_today()])

      assert {:error, {:invalid_field, "app", :not_a_string}} =
               Encode.entries_digest([Map.put(valid_entry(), "app", :arbor_shell)])
    end

    test "rejects traversal paths and mixed object-format OIDs" do
      traversal = Map.put(valid_entry(), "path", "apps/arbor_shell/../arbor_trust/lib/x.ex")

      assert {:error, {:invalid_field, "path", :traversal}} = Encode.entries_digest([traversal])

      sha1 = valid_entry(path: "apps/arbor_shell/lib/a.ex")
      sha256 = valid_entry(path: "apps/arbor_shell/lib/b.ex", blob_oid: String.duplicate("b", 64))
      assert {:error, :mixed_object_format} = Encode.entries_digest([sha1, sha256])
    end

    test "digest and JSON are independent of module-list order" do
      a = valid_entry(modules: ["Beta", "Alpha"])
      b = valid_entry(modules: ["Alpha", "Beta"])

      assert {:ok, d1} = Encode.entries_digest([a])
      assert {:ok, ^d1} = Encode.entries_digest([b])
      assert {:ok, json1} = Encode.encode_entries([a])
      assert {:ok, json2} = Encode.encode_entries([b])
      assert json1 == json2
    end

    test "rejects an oversized modules list" do
      entry = Map.put(valid_entry(), "modules", Enum.map(1..200, &"Mod#{&1}"))

      assert {:error, {:invalid_field, "modules", :unbounded}} = Encode.entries_digest([entry])
    end

    test "rejects duplicates in set-like module and OTP-role lists" do
      duplicate_modules = valid_entry(modules: ["Arbor.Example", "Arbor.Example"])
      duplicate_roles = valid_entry(otp_roles: ["genserver", "genserver"])

      assert {:error, {:invalid_field, "modules", :duplicate_items}} =
               Encode.entries_digest([duplicate_modules])

      assert {:error, {:invalid_field, "otp_roles", :duplicate_items}} =
               Encode.entries_digest([duplicate_roles])
    end
  end

  describe "review_digest/1" do
    test "digests a valid classification deterministically regardless of order" do
      a = valid_classification(path: "apps/arbor_shell/lib/a.ex")
      b = valid_classification(path: "apps/arbor_shell/lib/b.ex")

      assert {:ok, d1} = Encode.review_digest([a, b])
      assert {:ok, d2} = Encode.review_digest([b, a])
      assert d1 == d2
    end

    test "empty review list still yields a stable non-blank digest" do
      assert {:ok, digest} = Encode.review_digest([])
      assert {:ok, ^digest} = Encode.review_digest([])
      assert byte_size(digest) == 64
    end

    test "rejects an unknown component class" do
      classification = Map.put(valid_classification(), "class", "bogus_class")

      assert {:error, {:invalid_field, "class", :unknown_class}} =
               Encode.review_digest([classification])
    end

    test "rejects a blank rationale" do
      classification = Map.put(valid_classification(), "rationale", "")

      assert {:error, {:invalid_field, "rationale", :blank}} =
               Encode.review_digest([classification])
    end

    test "rejects an oversized rationale" do
      classification = Map.put(valid_classification(), "rationale", String.duplicate("x", 5000))

      assert {:error, {:invalid_field, "rationale", :unbounded}} =
               Encode.review_digest([classification])
    end

    test "rejects duplicate reviewed paths" do
      classification = valid_classification()

      assert {:error, :duplicate_classifications} =
               Encode.review_digest([classification, classification])
    end
  end

  describe "scan_manifest_digest/1" do
    test "rejects duplicate manifest paths" do
      triple = {"apps/arbor_shell/lib/a.ex", "100644", @oid}

      assert {:error, :duplicate_manifest_pairs} = Encode.scan_manifest_digest([triple, triple])
    end

    test "is independent of triple order" do
      t1 = {"apps/arbor_shell/lib/a.ex", "100644", @oid}
      t2 = {"apps/arbor_shell/lib/b.ex", "100644", String.duplicate("b", 40)}

      assert {:ok, d1} = Encode.scan_manifest_digest([t1, t2])
      assert {:ok, d2} = Encode.scan_manifest_digest([t2, t1])
      assert {:ok, ^d1} = Encode.scan_manifest_digest([t1, t2])
      assert d1 == d2
    end

    test "rejects malformed, traversal, oversized, and object-format-mismatched triples" do
      path = "apps/arbor_shell/lib/a.ex"

      assert {:error, :invalid_manifest_pairs} = Encode.scan_manifest_digest(:not_a_list)

      assert {:error, :invalid_manifest_pairs} =
               Encode.scan_manifest_digest([{1, "100644", @oid}])

      assert {:error, :invalid_manifest_pairs} = Encode.scan_manifest_digest([{path, "100644"}])

      assert {:error, :invalid_manifest_pairs} =
               Encode.scan_manifest_digest([{path, "120000", @oid}])

      assert {:error, :invalid_manifest_pairs} =
               Encode.scan_manifest_digest([{path, "100644", String.upcase(@oid)}])

      assert {:error, :invalid_manifest_pairs} =
               Encode.scan_manifest_digest([{"apps/../etc/passwd", "100644", @oid}])

      assert {:error, :invalid_manifest_pairs} =
               Encode.scan_manifest_digest([{String.duplicate("p", 5000), "100644", @oid}])

      assert {:error, :mixed_object_format} =
               Encode.scan_manifest_digest([
                 {path, "100644", @oid},
                 {"apps/arbor_shell/lib/b.ex", "100644", String.duplicate("b", 64)}
               ])
    end
  end

  describe "comparison_digest/1" do
    test "is independent of failure list and nested map key order" do
      f1 = %{"reason" => "missing_review", "detail" => "apps/arbor_shell/lib/a.ex"}
      f2 = %{"detail" => "apps/arbor_shell/lib/b.ex", "reason" => "extra_review"}
      f2_rekeyed = %{"reason" => "extra_review", "detail" => "apps/arbor_shell/lib/b.ex"}

      left = %{"status" => "mismatch", "failures" => [f1, f2], "failure_count" => 2}
      right = %{"status" => "mismatch", "failures" => [f2_rekeyed, f1], "failure_count" => 2}

      assert {:ok, d1} = Encode.comparison_digest(left)
      assert {:ok, d2} = Encode.comparison_digest(right)
      assert d1 == d2
    end

    test "length framing distinguishes delimiter-ambiguous failure sequences" do
      left = %{
        "status" => "mismatch",
        "failures" => [
          %{"reason" => "a", "detail" => "b\x1ec"},
          %{"reason" => "d", "detail" => "e"}
        ],
        "failure_count" => 2
      }

      right = %{
        "status" => "mismatch",
        "failures" => [
          %{"reason" => "a", "detail" => "b"},
          %{"reason" => "c\x1ed", "detail" => "e"}
        ],
        "failure_count" => 2
      }

      assert {:ok, left_digest} = Encode.comparison_digest(left)
      assert {:ok, right_digest} = Encode.comparison_digest(right)
      refute left_digest == right_digest
    end

    test "rejects duplicate failure rows" do
      failure = %{"reason" => "missing_review", "detail" => "apps/arbor_shell/lib/a.ex"}

      assert {:error, {:invalid_field, "failures", :duplicate_failures}} =
               Encode.comparison_digest(%{
                 "status" => "mismatch",
                 "failures" => [failure, failure],
                 "failure_count" => 2
               })
    end

    test "rejects mixed keys, structs, and inconsistent status/count" do
      assert {:error, :non_string_keys} =
               Encode.comparison_digest(%{
                 "status" => "match",
                 "failures" => [],
                 failure_count: 0
               })

      assert {:error, :invalid_map} = Encode.comparison_digest(Date.utc_today())

      assert {:error, {:invalid_field, "status", :inconsistent_status}} =
               Encode.comparison_digest(%{
                 "status" => "match",
                 "failures" => [
                   %{"reason" => "missing_review", "detail" => "apps/arbor_shell/lib/a.ex"}
                 ],
                 "failure_count" => 1
               })
    end
  end

  describe "encode_report/1" do
    test "produces byte-identical output across repeated calls" do
      report = valid_report()

      assert {:ok, bytes1} = Encode.encode_report(report)
      assert {:ok, bytes2} = Encode.encode_report(report)
      assert bytes1 == bytes2
    end

    test "accepts exact match and stale-review mismatch semantics" do
      classification = valid_classification()

      exact_match =
        valid_report()
        |> Map.put("status", "match")
        |> Map.put("classifications", [classification])
        |> Map.put("comparison", %{"status" => "match", "failures" => [], "failure_count" => 0})
        |> put_in(["counts", "reviewed_files"], 1)
        |> put_in(["counts", "unreviewed_files"], 0)
        |> put_in(["counts", "by_class", "trusted_host"], 1)
        |> bind_digests()

      assert {:ok, _json} = Encode.encode_report(exact_match)

      stale_oid = String.duplicate("b", 40)
      stale_classification = %{classification | "blob_oid" => stale_oid}

      stale_mismatch =
        exact_match
        |> Map.put("status", "mismatch")
        |> Map.put("classifications", [stale_classification])
        |> Map.put("comparison", %{
          "status" => "mismatch",
          "failures" => [
            %{
              "reason" => "stale_blob",
              "detail" => "apps/arbor_shell/lib/example.ex expected=#{@oid} actual=#{stale_oid}"
            }
          ],
          "failure_count" => 1
        })
        |> bind_digests()

      assert {:ok, _json} = Encode.encode_report(stale_mismatch)
    end

    test "platform_apps and component_classes are canonicalized regardless of input order" do
      report = valid_report()
      shuffled = %{report | "platform_apps" => Enum.reverse(Core.platform_apps())}

      assert {:ok, canonical} = Encode.encode_report(report)
      assert {:ok, from_shuffled} = Encode.encode_report(shuffled)
      assert canonical == from_shuffled
    end

    test "rejects a report missing the provenance field" do
      report = Map.delete(valid_report(), "provenance")

      assert {:error, {:field_mismatch, %{missing: ["provenance"]}}} =
               Encode.encode_report(report)
    end

    test "rejects an unknown top-level mode" do
      report = Map.put(valid_report(), "mode", "delete_everything")

      assert {:error, {:invalid_field, "mode", :invalid_mode}} = Encode.encode_report(report)
    end

    test "rejects a platform_apps list missing an app" do
      report = %{
        valid_report()
        | "platform_apps" => List.delete(Core.platform_apps(), "arbor_trust")
      }

      assert {:error, {:invalid_field, "platform_apps", :invalid_platform_apps}} =
               Encode.encode_report(report)
    end

    test "rejects a failure_count that does not match the failures list" do
      report = %{
        valid_report()
        | "comparison" => %{"status" => "mismatch", "failures" => [], "failure_count" => 1}
      }

      assert {:error, {:invalid_field, "failure_count", :mismatched_count}} =
               Encode.encode_report(report)
    end

    test "canonicalizes nested failure maps regardless of input order" do
      report = mismatch_report()
      [first, second] = report["comparison"]["failures"]

      reordered = %{
        report
        | "comparison" => %{
            "status" => "mismatch",
            "failure_count" => 2,
            "failures" => [
              %{"detail" => second["detail"], "reason" => second["reason"]},
              %{"reason" => first["reason"], "detail" => first["detail"]}
            ]
          }
      }

      reordered = bind_digests(reordered)

      assert {:ok, bytes1} = Encode.encode_report(report)
      assert {:ok, bytes2} = Encode.encode_report(reordered)
      assert bytes1 == bytes2

      extra = "\"reason\":\"extra_review\",\"detail\":\"apps/arbor_shell/lib/c.ex\""
      missing = "\"reason\":\"missing_review\",\"detail\":\"apps/arbor_shell/lib/b.ex\""
      assert bytes1 =~ extra
      assert bytes1 =~ missing
      assert :binary.match(bytes1, extra) < :binary.match(bytes1, missing)
    end

    test "rejects false matches and incomplete or invented comparison failures" do
      report = mismatch_report()

      false_match =
        report
        |> Map.put("status", "match")
        |> Map.put("comparison", %{"status" => "match", "failures" => [], "failure_count" => 0})
        |> bind_digests()

      assert {:error, {:invalid_field, "comparison", :semantic_mismatch}} =
               Encode.encode_report(false_match)

      [first_failure, second_failure] = report["comparison"]["failures"]

      incomplete =
        report
        |> Map.put("comparison", %{
          "status" => "mismatch",
          "failures" => [first_failure],
          "failure_count" => 1
        })
        |> bind_digests()

      assert {:error, {:invalid_field, "comparison", :semantic_mismatch}} =
               Encode.encode_report(incomplete)

      invented =
        report
        |> Map.put("comparison", %{
          "status" => "mismatch",
          "failures" => [
            first_failure,
            %{second_failure | "detail" => "apps/arbor_shell/lib/invented.ex"}
          ],
          "failure_count" => 2
        })
        |> bind_digests()

      assert {:error, {:invalid_field, "comparison", :semantic_mismatch}} =
               Encode.encode_report(invented)
    end

    test "rejects a stale reviewed blob hidden behind a false match" do
      classification = valid_classification(blob_oid: String.duplicate("b", 40))

      report =
        valid_report()
        |> Map.put("status", "match")
        |> Map.put("classifications", [classification])
        |> Map.put("comparison", %{"status" => "match", "failures" => [], "failure_count" => 0})
        |> put_in(["counts", "reviewed_files"], 1)
        |> put_in(["counts", "unreviewed_files"], 0)
        |> put_in(["counts", "by_class", "trusted_host"], 1)
        |> bind_digests()

      assert {:error, {:invalid_field, "comparison", :semantic_mismatch}} =
               Encode.encode_report(report)
    end

    test "rejects an entry whose path and app ownership disagree" do
      entry = valid_entry(app: "arbor_trust")

      report =
        valid_report()
        |> Map.put("entries", [entry])
        |> put_in(["counts", "by_app", "arbor_shell"], 0)
        |> put_in(["counts", "by_app", "arbor_trust"], 1)
        |> bind_digests()

      assert {:error, {:invalid_field, "app", :path_app_mismatch}} =
               Encode.encode_report(report)
    end

    test "rejects inconsistent status, counts, and unbound digests" do
      report = valid_report()

      assert {:error, {:invalid_field, "status", :status_mismatch}} =
               Encode.encode_report(%{report | "status" => "match"})

      assert {:error, {:invalid_field, "counts", :inconsistent_total_files}} =
               Encode.encode_report(put_in(report, ["counts", "total_files"], 99))

      assert {:error, {:invalid_field, "entries_digest", :digest_mismatch}} =
               Encode.encode_report(
                 put_in(report, ["provenance", "entries_digest"], String.duplicate("f", 64))
               )

      assert {:error, {:invalid_field, "schema", :invalid_schema}} =
               Encode.encode_report(%{report | "schema" => "not-the-schema"})
    end

    test "rejects mixed keys, structs, and non-JSON values on the report" do
      report = valid_report()

      assert {:error, :non_string_keys} =
               Encode.encode_report(Map.put(report, :status, "unreviewed"))

      assert {:error, :invalid_map} = Encode.encode_report(Date.utc_today())

      assert {:error, :invalid_entries} =
               Encode.encode_report(%{report | "entries" => [self()]})
    end
  end

  defp valid_entry(overrides \\ []) do
    %{
      "path" => "apps/arbor_shell/lib/example.ex",
      "blob_oid" => @oid,
      "mode" => "100644",
      "byte_size" => 42,
      "app" => "arbor_shell",
      "modules" => ["Arbor.Shell.Example"],
      "otp_roles" => ["genserver"],
      "configuration" => false,
      "ownership" => false,
      "registry" => false,
      "process" => false,
      "native" => false,
      "network" => false,
      "filesystem_scan" => false,
      "dynamic_code" => false,
      "telemetry" => false
    }
    |> put_overrides(overrides)
  end

  defp valid_classification(overrides \\ []) do
    %{
      "path" => "apps/arbor_shell/lib/example.ex",
      "blob_oid" => @oid,
      "class" => "trusted_host",
      "rationale" => "Owns process launch authorization."
    }
    |> put_overrides(overrides)
  end

  defp valid_report do
    bind_digests(%{
      "schema" => "arbor.packaging.platform_inventory.v1",
      "mode" => "report",
      "status" => "unreviewed",
      "output" => "human",
      "platform_apps" => Core.platform_apps(),
      "component_classes" => Core.component_classes(),
      "counts" => %{
        "total_files" => 1,
        "reviewed_files" => 0,
        "unreviewed_files" => 1,
        "by_app" => Map.new(Core.platform_apps(), &{&1, 0}) |> Map.put("arbor_shell", 1),
        "by_class" => Map.new(Core.component_classes(), &{&1, 0})
      },
      "entries" => [valid_entry()],
      "classifications" => [],
      "comparison" => %{"status" => "unreviewed", "failures" => [], "failure_count" => 0},
      "provenance" => %{"head_tree_oid" => @oid}
    })
  end

  defp mismatch_report do
    entries = [
      valid_entry(path: "apps/arbor_shell/lib/a.ex"),
      valid_entry(path: "apps/arbor_shell/lib/b.ex")
    ]

    classifications = [
      valid_classification(path: "apps/arbor_shell/lib/a.ex"),
      valid_classification(path: "apps/arbor_shell/lib/c.ex")
    ]

    bind_digests(%{
      "schema" => "arbor.packaging.platform_inventory.v1",
      "mode" => "report",
      "status" => "mismatch",
      "output" => "human",
      "platform_apps" => Core.platform_apps(),
      "component_classes" => Core.component_classes(),
      "counts" => %{
        "total_files" => 2,
        "reviewed_files" => 1,
        "unreviewed_files" => 1,
        "by_app" => Map.new(Core.platform_apps(), &{&1, 0}) |> Map.put("arbor_shell", 2),
        "by_class" => Map.new(Core.component_classes(), &{&1, 0}) |> Map.put("trusted_host", 2)
      },
      "entries" => entries,
      "classifications" => classifications,
      "comparison" => %{
        "status" => "mismatch",
        "failures" => [
          %{"reason" => "missing_review", "detail" => "apps/arbor_shell/lib/b.ex"},
          %{"reason" => "extra_review", "detail" => "apps/arbor_shell/lib/c.ex"}
        ],
        "failure_count" => 2
      },
      "provenance" => %{"head_tree_oid" => @oid}
    })
  end

  defp bind_digests(report) do
    entries = Map.fetch!(report, "entries")
    classifications = Map.fetch!(report, "classifications")
    comparison = Map.fetch!(report, "comparison")
    triples = Enum.map(entries, &{&1["path"], &1["mode"], &1["blob_oid"]})

    {:ok, index_digest} = Encode.scan_manifest_digest(triples)
    {:ok, entries_digest} = Encode.entries_digest(entries)
    {:ok, review_digest} = Encode.review_digest(classifications)
    {:ok, comparison_digest} = Encode.comparison_digest(comparison)

    provenance =
      report
      |> Map.fetch!("provenance")
      |> Map.merge(%{
        "index_manifest_digest" => index_digest,
        "entries_digest" => entries_digest,
        "review_digest" => review_digest,
        "comparison_digest" => comparison_digest
      })

    Map.put(report, "provenance", provenance)
  end

  defp put_overrides(map, overrides) do
    Enum.reduce(overrides, map, fn {key, value}, acc ->
      string_key = if is_atom(key), do: Atom.to_string(key), else: key
      Map.put(acc, string_key, value)
    end)
  end
end
