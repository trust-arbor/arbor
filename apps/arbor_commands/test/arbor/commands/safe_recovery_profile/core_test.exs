defmodule Arbor.Commands.SafeRecoveryProfile.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryProfile.{Core, Encode}

  @moduletag :fast

  describe "project/1 committed candidate" do
    test "admits the frozen conformant blocked intent and sorts closed lists" do
      candidate = load_candidate()

      assert {:ok, profile} = Core.project(candidate)
      assert {:ok, ^profile} = Core.project(profile)

      assert profile["schema"] == Core.schema()
      assert profile["version"] == 1
      assert profile["profile"] == Core.profile_name()
      assert profile["evidence_status"] == "conformant"
      assert profile["architecture_status"] == "blocked"
      refute Map.has_key?(profile, "profile_digest")
      refute Map.has_key?(profile, "digest")
      refute Map.has_key?(profile["source_inventory"], "head_tree_oid")

      assert profile["source_inventory"] == %{
               "platform_inventory_schema" => "arbor.packaging.platform_inventory.v1",
               "selected_file_count" => 318,
               "selected_index_digest" =>
                 "1c55e299738edbbea68359f91332ad2420df679a0b7e8040b6ef53cbf8ed21a2",
               "entries_digest" =>
                 "75cd2f9aa708c68aa3c5981ce00c82a339ca40d3a351caf5a05a18f081943cb0",
               "review_digest" =>
                 "dd307c2ab8365077471a9c2e4a62b79bb5869b0ff5b732ba30390b89e0394172"
             }

      assert Enum.map(profile["selected_applications"], & &1["name"]) == [
               "arbor_kernel",
               "arbor_kernel_runtime",
               "arbor_security",
               "arbor_trust"
             ]

      assert Enum.map(profile["selected_applications"], & &1["role"]) == [
               "stage_zero",
               "runtime_mechanism",
               "trusted_host",
               "trusted_host"
             ]

      assert Enum.map(profile["mandatory_host_responsibilities"], & &1["id"]) ==
               Enum.sort(Enum.map(candidate["mandatory_host_responsibilities"], & &1["id"]))

      assert Enum.map(profile["forbidden_facilities"], & &1["id"]) ==
               Enum.sort(Enum.map(candidate["forbidden_facilities"], & &1["id"]))

      assert Enum.map(profile["expected_external_dependencies"], & &1["id"]) ==
               Enum.sort(Enum.map(candidate["expected_external_dependencies"], & &1["id"]))

      assert Enum.map(profile["blockers"], &{&1["id"], &1["owner"]}) ==
               candidate["blockers"]
               |> Enum.map(&{&1["id"], &1["owner"]})
               |> Enum.sort_by(&elem(&1, 0))

      assert length(profile["blockers"]) == 13
    end

    test "decoded committed candidate already equals its projected profile" do
      candidate = load_candidate()
      assert {:ok, profile} = Core.project(candidate)
      assert candidate == profile
    end

    test "accepts a closed atom-keyed candidate and reordered lists as the same profile" do
      candidate = load_candidate()
      assert {:ok, expected} = Core.project(candidate)

      reordered = %{
        candidate
        | "selected_applications" => Enum.reverse(candidate["selected_applications"]),
          "mandatory_host_responsibilities" =>
            Enum.reverse(candidate["mandatory_host_responsibilities"]),
          "forbidden_facilities" => Enum.reverse(candidate["forbidden_facilities"]),
          "expected_external_dependencies" =>
            Enum.reverse(candidate["expected_external_dependencies"]),
          "blockers" => Enum.reverse(candidate["blockers"])
      }

      assert {:ok, ^expected} = Core.project(reordered)
      assert {:ok, ^expected} = Core.project(atom_candidate(candidate))
    end
  end

  describe "project/1 frozen v1 status" do
    test "keeps conformant evidence with blocked architecture" do
      candidate = load_candidate()
      assert {:ok, profile} = Core.project(candidate)
      assert profile["evidence_status"] == "conformant"
      assert profile["architecture_status"] == "blocked"
      assert profile["blockers"] != []
    end

    test "rejects ready architecture while blockers remain" do
      candidate = %{load_candidate() | "architecture_status" => "ready"}

      assert {:error, {:invalid_field, "architecture_status", :unknown_architecture_status}} =
               Core.project(candidate)
    end

    test "rejects blocked architecture without blockers" do
      candidate = %{load_candidate() | "blockers" => []}

      assert {:error, {:invalid_field, "architecture_status", :inconsistent_status}} =
               Core.project(candidate)
    end

    test "security regression: project/1 rejects relabeling the frozen candidate as ready even when blockers are removed" do
      candidate =
        load_candidate()
        |> Map.put("architecture_status", "ready")
        |> Map.put("blockers", [])

      assert {:error, {:invalid_field, "architecture_status", :unknown_architecture_status}} =
               Core.project(candidate)
    end
  end

  describe "project/1 closed sets and pairings" do
    test "rejects unknown, missing, extra, and swapped application pairings" do
      candidate = load_candidate()
      [kernel | rest] = candidate["selected_applications"]

      unknown = %{kernel | "name" => "arbor_shell"}

      assert {:error, {:invalid_field, "name", :unknown_name}} =
               Core.project(%{candidate | "selected_applications" => [unknown | rest]})

      missing = List.delete_at(candidate["selected_applications"], -1)

      assert {:error, {:invalid_field, "selected_applications", :set_mismatch}} =
               Core.project(%{candidate | "selected_applications" => missing})

      extra = candidate["selected_applications"] ++ [Map.put(kernel, "name", "arbor_dashboard")]

      assert {:error, {:invalid_field, "name", :unknown_name}} =
               Core.project(%{candidate | "selected_applications" => extra})

      swapped = [
        %{kernel | "role" => "trusted_host"}
        | Enum.map(rest, fn
            %{"name" => "arbor_security"} = app -> %{app | "role" => "stage_zero"}
            app -> app
          end)
      ]

      assert {:error, {:invalid_field, "selected_applications", :pairing_mismatch}} =
               Core.project(%{candidate | "selected_applications" => swapped})
    end

    test "rejects unknown ids, owners, kinds, and incomplete closed lists" do
      candidate = load_candidate()
      [responsibility | rest_responsibilities] = candidate["mandatory_host_responsibilities"]
      [facility | rest_facilities] = candidate["forbidden_facilities"]
      [dependency | rest_dependencies] = candidate["expected_external_dependencies"]
      [blocker | rest_blockers] = candidate["blockers"]

      assert {:error, {:invalid_field, "id", :unknown_id}} =
               Core.project(%{
                 candidate
                 | "mandatory_host_responsibilities" => [
                     %{responsibility | "id" => "invented_responsibility"}
                     | rest_responsibilities
                   ]
               })

      assert {:error, {:invalid_field, "owner", :unknown_owner}} =
               Core.project(%{
                 candidate
                 | "mandatory_host_responsibilities" => [
                     %{responsibility | "owner" => "arbor_dashboard"}
                     | rest_responsibilities
                   ]
               })

      assert {:error, {:invalid_field, "id", :unknown_id}} =
               Core.project(%{
                 candidate
                 | "forbidden_facilities" => [
                     %{facility | "id" => "invented_facility"} | rest_facilities
                   ]
               })

      assert {:error, {:invalid_field, "kind", :unknown_kind}} =
               Core.project(%{
                 candidate
                 | "expected_external_dependencies" => [
                     %{dependency | "kind" => "optional_extension"} | rest_dependencies
                   ]
               })

      assert {:error, {:invalid_field, "owner", :unknown_owner}} =
               Core.project(%{
                 candidate
                 | "blockers" => [%{blocker | "owner" => "invented_owner"} | rest_blockers]
               })

      assert {:error, {:invalid_field, "forbidden_facilities", :set_mismatch}} =
               Core.project(%{
                 candidate
                 | "forbidden_facilities" => rest_facilities
               })
    end

    test "rejects duplicate names and ids" do
      candidate = load_candidate()
      [app, second | rest_apps] = candidate["selected_applications"]
      [blocker, second_blocker | rest_blockers] = candidate["blockers"]

      assert {:error, {:invalid_field, "selected_applications", :duplicate_ids}} =
               Core.project(%{
                 candidate
                 | "selected_applications" => [app, %{second | "name" => app["name"]} | rest_apps]
               })

      assert {:error, {:invalid_field, "blockers", :duplicate_ids}} =
               Core.project(%{
                 candidate
                 | "blockers" => [
                     blocker,
                     %{second_blocker | "id" => blocker["id"]} | rest_blockers
                   ]
               })
    end
  end

  describe "project/1 malformed input" do
    test "rejects structs, mixed keys, missing fields, extra fields, and unknown enums" do
      candidate = load_candidate()

      assert {:error, :invalid_candidate} = Core.project(Date.utc_today())
      assert {:error, :invalid_candidate} = Core.project("not-a-map")

      oversized_map = Map.new(1..17, fn index -> {"field_#{index}", index} end)
      assert {:error, :unbounded} = Core.project(oversized_map)

      assert {:error, {:invalid_field, "schema", :not_a_string}} =
               Core.project(%{candidate | "schema" => self()})

      mixed = candidate |> Map.delete("schema") |> Map.put(:schema, candidate["schema"])
      assert {:error, :mixed_keys} = Core.project(mixed)

      alias_collision = Map.put(candidate, :blockers, candidate["blockers"])
      assert {:error, :mixed_keys} = Core.project(alias_collision)

      assert {:error, {:field_mismatch, %{missing: ["blockers"], extra_count: 0}}} =
               Core.project(Map.delete(candidate, "blockers"))

      assert {:error, {:field_mismatch, %{missing: [], extra_count: 1}}} =
               Core.project(Map.put(candidate, "head_tree_oid", String.duplicate("a", 40)))

      inventory =
        Map.put(candidate["source_inventory"], "head_tree_oid", String.duplicate("a", 40))

      assert {:error,
              {:invalid_field, "source_inventory",
               {:field_mismatch, %{missing: [], extra_count: 1}}}} =
               Core.project(%{candidate | "source_inventory" => inventory})

      assert {:error, {:invalid_field, "architecture_status", :unknown_architecture_status}} =
               Core.project(%{candidate | "architecture_status" => "available"})

      assert {:error, {:invalid_field, "evidence_status", :unknown_evidence_status}} =
               Core.project(%{candidate | "evidence_status" => "ready"})
    end

    test "field-mismatch diagnostics stay bounded and do not echo unknown keys" do
      candidate = load_candidate()
      unknown = "hostile_unknown_field"

      assert {:error, {:field_mismatch, diagnostic}} =
               Core.project(Map.put(candidate, unknown, "payload"))

      assert diagnostic == %{missing: [], extra_count: 1}
      refute inspect(diagnostic) =~ unknown
    end

    test "rejects oversized unknown keys without echoing them" do
      candidate = load_candidate()
      oversized_key = String.duplicate("k", 257)

      assert {:error, :unbounded} = Core.project(Map.put(candidate, oversized_key, "payload"))

      assert {:error, :invalid_map_keys} =
               Core.project(Map.put(candidate, <<0xFF>>, "payload"))
    end

    test "rejects malformed digests, counts, and text" do
      candidate = load_candidate()
      inventory = candidate["source_inventory"]
      [app | rest_apps] = candidate["selected_applications"]

      assert {:error, {:invalid_field, "selected_index_digest", :invalid_digest}} =
               Core.project(%{
                 candidate
                 | "source_inventory" => %{
                     inventory
                     | "selected_index_digest" =>
                         String.upcase(inventory["selected_index_digest"])
                   }
               })

      assert {:error, {:invalid_field, "entries_digest", :digest_mismatch}} =
               Core.project(%{
                 candidate
                 | "source_inventory" => %{
                     inventory
                     | "entries_digest" => String.duplicate("0", 64)
                   }
               })

      assert {:error, {:invalid_field, "selected_file_count", :count_mismatch}} =
               Core.project(%{
                 candidate
                 | "source_inventory" => %{inventory | "selected_file_count" => 319}
               })

      assert {:error, {:invalid_field, "selected_file_count", :not_an_integer}} =
               Core.project(%{
                 candidate
                 | "source_inventory" => %{inventory | "selected_file_count" => "318"}
               })

      assert {:error, {:invalid_field, "rationale", :blank}} =
               Core.project(%{
                 candidate
                 | "selected_applications" => [%{app | "rationale" => "   "} | rest_apps]
               })

      assert {:error, {:invalid_field, "rationale", :control_character}} =
               Core.project(%{
                 candidate
                 | "selected_applications" => [%{app | "rationale" => "has\nnewline"} | rest_apps]
               })

      assert {:error, {:invalid_field, "rationale", :invalid_utf8}} =
               Core.project(%{
                 candidate
                 | "selected_applications" => [%{app | "rationale" => <<0xFF>>} | rest_apps]
               })

      assert {:error, {:invalid_field, "rationale", :unbounded}} =
               Core.project(%{
                 candidate
                 | "selected_applications" => [
                     %{app | "rationale" => String.duplicate("x", 4001)} | rest_apps
                   ]
               })
    end

    test "rejects improper, oversized, and non-list collections" do
      candidate = load_candidate()
      [blocker | _] = candidate["blockers"]

      improper = [blocker | :not_a_list]

      assert {:error, {:invalid_field, "blockers", :improper_list}} =
               Core.project(%{candidate | "blockers" => improper})

      oversized =
        Enum.map(1..33, fn index ->
          %{
            "id" => "blocker_#{index}",
            "owner" => "p1a_safe_profile_closure",
            "rationale" => "oversized"
          }
        end)

      assert {:error, {:invalid_field, "blockers", :unbounded}} =
               Core.project(%{candidate | "blockers" => oversized})

      assert {:error, {:invalid_field, "blockers", :not_a_list}} =
               Core.project(%{candidate | "blockers" => %{}})

      assert {:error, {:invalid_field, "selected_applications", :invalid_map}} =
               Core.project(%{candidate | "selected_applications" => [Date.utc_today()]})
    end
  end

  describe "project/1 encode handoff" do
    test "projects the committed candidate into a profile Encode accepts" do
      assert {:ok, profile} = Core.project(load_candidate())
      assert :ok = Encode.validate_profile(profile)
    end
  end

  defp candidate_path do
    Application.app_dir(:arbor_commands, "priv/packaging/safe_recovery_profile.v1.json")
  end

  defp load_candidate do
    candidate_path()
    |> File.read!()
    |> Jason.decode!()
  end

  defp atom_candidate(candidate) do
    %{
      schema: candidate["schema"],
      version: candidate["version"],
      profile: candidate["profile"],
      evidence_status: candidate["evidence_status"],
      architecture_status: candidate["architecture_status"],
      source_inventory: %{
        platform_inventory_schema: candidate["source_inventory"]["platform_inventory_schema"],
        selected_file_count: candidate["source_inventory"]["selected_file_count"],
        selected_index_digest: candidate["source_inventory"]["selected_index_digest"],
        entries_digest: candidate["source_inventory"]["entries_digest"],
        review_digest: candidate["source_inventory"]["review_digest"]
      },
      selected_applications: Enum.map(candidate["selected_applications"], &atom_application/1),
      mandatory_host_responsibilities:
        Enum.map(candidate["mandatory_host_responsibilities"], &atom_owned/1),
      forbidden_facilities: Enum.map(candidate["forbidden_facilities"], &atom_facility/1),
      expected_external_dependencies:
        Enum.map(candidate["expected_external_dependencies"], &atom_dependency/1),
      blockers: Enum.map(candidate["blockers"], &atom_owned/1)
    }
  end

  defp atom_application(entry) do
    %{name: entry["name"], role: entry["role"], rationale: entry["rationale"]}
  end

  defp atom_owned(entry) do
    %{id: entry["id"], owner: entry["owner"], rationale: entry["rationale"]}
  end

  defp atom_facility(entry) do
    %{id: entry["id"], rationale: entry["rationale"]}
  end

  defp atom_dependency(entry) do
    %{id: entry["id"], kind: entry["kind"], rationale: entry["rationale"]}
  end
end
