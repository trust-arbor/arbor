defmodule Arbor.Commands.SafeRecoveryProfile.EncodeTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryProfile.{Core, Encode}

  @moduletag :fast

  @candidate_path Path.expand(
                    "../../../../../priv/packaging/safe_recovery_profile.v1.json",
                    __DIR__
                  )

  describe "validate_profile/1" do
    test "accepts the projected committed candidate" do
      profile = projected_candidate()
      assert :ok = Encode.validate_profile(profile)
    end

    test "accepts conformant blocked and conformant ready independently" do
      blocked = projected_candidate()
      assert blocked["evidence_status"] == "conformant"
      assert blocked["architecture_status"] == "blocked"
      assert :ok = Encode.validate_profile(blocked)

      ready = %{blocked | "architecture_status" => "ready", "blockers" => []}
      assert :ok = Encode.validate_profile(ready)
    end

    test "rejects ready-with-blockers and blocked-without-blockers" do
      profile = projected_candidate()

      assert {:error, {:invalid_field, "architecture_status", :inconsistent_status}} =
               Encode.validate_profile(%{profile | "architecture_status" => "ready"})

      assert {:error, {:invalid_field, "architecture_status", :inconsistent_status}} =
               Encode.validate_profile(%{profile | "blockers" => []})
    end

    test "rejects unknown, missing, extra, and mixed fields" do
      profile = projected_candidate()

      assert {:error, {:invalid_field, "schema", :invalid_schema}} =
               Encode.validate_profile(%{profile | "schema" => "arbor.packaging.other.v1"})

      assert {:error, {:field_mismatch, %{missing: ["blockers"]}}} =
               Encode.validate_profile(Map.delete(profile, "blockers"))

      assert {:error, {:field_mismatch, %{extra: ["profile_digest"]}}} =
               Encode.validate_profile(Map.put(profile, "profile_digest", String.duplicate("a", 64)))

      mixed = profile |> Map.delete("version") |> Map.put(:version, 1)
      assert {:error, :mixed_keys} = Encode.validate_profile(mixed)

      atom_only = %{schema: profile["schema"]}
      assert {:error, :non_string_keys} = Encode.validate_profile(atom_only)
    end

    test "rejects structs, duplicate ids, and malformed digest or count values" do
      profile = projected_candidate()
      inventory = profile["source_inventory"]
      [blocker, second | rest] = profile["blockers"]

      assert {:error, :invalid_profile} = Encode.validate_profile(Date.utc_today())
      assert {:error, :invalid_profile} = Encode.validate_profile([profile])

      assert {:error, {:invalid_field, "blockers", :duplicate_ids}} =
               Encode.validate_profile(%{
                 profile
                 | "blockers" => [blocker, %{second | "id" => blocker["id"]} | rest]
               })

      assert {:error, {:invalid_field, "selected_index_digest", :invalid_digest}} =
               Encode.validate_profile(%{
                 profile
                 | "source_inventory" => %{
                     inventory
                     | "selected_index_digest" => "not-a-digest"
                   }
               })

      assert {:error, {:invalid_field, "review_digest", :digest_mismatch}} =
               Encode.validate_profile(%{
                 profile
                 | "source_inventory" => %{
                     inventory
                     | "review_digest" => String.duplicate("f", 64)
                   }
               })

      assert {:error, {:invalid_field, "selected_file_count", :negative}} =
               Encode.validate_profile(%{
                 profile
                 | "source_inventory" => %{inventory | "selected_file_count" => -1}
               })

      assert {:error, {:invalid_field, "selected_file_count", :unbounded}} =
               Encode.validate_profile(%{
                 profile
                 | "source_inventory" => %{inventory | "selected_file_count" => 5_001}
               })
    end

    test "rejects improper lists, oversized lists, and control-bearing text" do
      profile = projected_candidate()
      [app | rest] = profile["selected_applications"]
      [facility | _] = profile["forbidden_facilities"]

      assert {:error, {:invalid_field, "forbidden_facilities", :improper_list}} =
               Encode.validate_profile(%{
                 profile
                 | "forbidden_facilities" => [facility | :tail]
               })

      oversized_apps =
        Enum.map(1..33, fn index ->
          %{
            "name" => "app_#{index}",
            "role" => "stage_zero",
            "rationale" => "oversized"
          }
        end)

      assert {:error, {:invalid_field, "selected_applications", :unbounded}} =
               Encode.validate_profile(%{profile | "selected_applications" => oversized_apps})

      assert {:error, {:invalid_field, "rationale", :control_character}} =
               Encode.validate_profile(%{
                 profile
                 | "selected_applications" => [
                     %{app | "rationale" => "bad\0rationale"} | rest
                   ]
               })
    end
  end

  describe "encode_profile/1 and profile_digest/1" do
    test "emits compact deterministic bytes and a domain-separated digest" do
      profile = projected_candidate()

      assert {:ok, bytes} = Encode.encode_profile(profile)
      assert {:ok, ^bytes} = Encode.encode_profile(profile)
      refute String.contains?(bytes, "\n")
      refute String.contains?(bytes, "\": ")
      assert String.starts_with?(
               bytes,
               "{\"schema\":\"arbor.packaging.safe_recovery_profile.intent.v1\",\"version\":1,\"profile\":\"safe_recovery\",\"evidence_status\":\"conformant\",\"architecture_status\":\"blocked\""
             )

      assert :binary.match(
               bytes,
               "\"name\":\"arbor_kernel\",\"role\":\"stage_zero\",\"rationale\":"
             ) != :nomatch

      assert :binary.match(
               bytes,
               "\"id\":\"boot_manifest_verification\",\"owner\":\"arbor_kernel\""
             ) != :nomatch

      refute String.contains?(bytes, "profile_digest")

      expected_digest =
        :crypto.hash(:sha256, [Encode.intent_domain(), bytes])
        |> Base.encode16(case: :lower)

      assert {:ok, ^expected_digest} = Encode.profile_digest(profile)
      assert {:ok, ^expected_digest} = Encode.profile_digest(profile)
      assert byte_size(expected_digest) == 64
      assert expected_digest == String.downcase(expected_digest)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_digest)
    end

    test "canonical bytes and digest ignore semantically identical reordering" do
      profile = projected_candidate()
      candidate = load_candidate()

      reordered = %{
        profile
        | "selected_applications" => Enum.reverse(profile["selected_applications"]),
          "mandatory_host_responsibilities" =>
            Enum.reverse(profile["mandatory_host_responsibilities"]),
          "forbidden_facilities" => Enum.reverse(profile["forbidden_facilities"]),
          "expected_external_dependencies" =>
            Enum.reverse(profile["expected_external_dependencies"]),
          "blockers" => Enum.reverse(profile["blockers"])
      }

      rekeyed_inventory = %{
        "review_digest" => profile["source_inventory"]["review_digest"],
        "entries_digest" => profile["source_inventory"]["entries_digest"],
        "selected_index_digest" => profile["source_inventory"]["selected_index_digest"],
        "selected_file_count" => profile["source_inventory"]["selected_file_count"],
        "platform_inventory_schema" => profile["source_inventory"]["platform_inventory_schema"]
      }

      rekeyed = %{reordered | "source_inventory" => rekeyed_inventory}

      assert {:ok, bytes} = Encode.encode_profile(profile)
      assert {:ok, ^bytes} = Encode.encode_profile(reordered)
      assert {:ok, ^bytes} = Encode.encode_profile(rekeyed)
      assert {:ok, ^bytes} = Encode.encode_profile(candidate)

      assert {:ok, digest} = Encode.profile_digest(profile)
      assert {:ok, ^digest} = Encode.profile_digest(reordered)
      assert {:ok, ^digest} = Encode.profile_digest(rekeyed)
      assert {:ok, ^digest} = Encode.profile_digest(candidate)
    end

    test "decoding the committed candidate, projecting, and encoding is deterministic" do
      raw = File.read!(@candidate_path)
      assert String.contains?(raw, "\n  ")
      refute String.contains?(raw, "profile_digest")

      assert {:ok, decoded} = Jason.decode(raw)
      assert {:ok, projected} = Core.project(decoded)
      assert {:ok, bytes} = Encode.encode_profile(projected)
      assert {:ok, ^bytes} = Encode.encode_profile(projected)

      assert {:ok, decoded_again} = Jason.decode(raw)
      assert {:ok, projected_again} = Core.project(decoded_again)
      assert {:ok, ^bytes} = Encode.encode_profile(projected_again)

      assert {:ok, from_bytes} = Jason.decode(bytes)
      assert {:ok, reprojected} = Core.project(from_bytes)
      assert {:ok, ^bytes} = Encode.encode_profile(reprojected)
      assert projected == reprojected
    end

    test "rejects structs and mixed keys before hashing or encoding" do
      profile = projected_candidate()

      assert {:error, :invalid_profile} = Encode.encode_profile(Date.utc_today())
      assert {:error, :invalid_profile} = Encode.profile_digest(Date.utc_today())

      mixed = Map.put(profile, :schema, profile["schema"])
      assert {:error, :mixed_keys} = Encode.encode_profile(mixed)
      assert {:error, :mixed_keys} = Encode.profile_digest(mixed)
    end
  end

  defp load_candidate do
    @candidate_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp projected_candidate do
    {:ok, profile} = Core.project(load_candidate())
    profile
  end
end
