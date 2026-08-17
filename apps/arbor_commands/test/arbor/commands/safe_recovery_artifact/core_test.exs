defmodule Arbor.Commands.SafeRecoveryArtifact.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.{Core, Derive, Encode}
  alias Arbor.Commands.SafeRecoveryArtifactFixture, as: Fixture
  alias Arbor.Commands.SafeRecoveryProfile

  @moduletag :fast

  describe "project/1 golden fixture" do
    test "projects closed fields, classes, findings, and identical reproducibility" do
      candidate = Fixture.candidate()
      assert {:ok, manifest} = Core.project(candidate)

      assert manifest["schema"] == "arbor.packaging.safe_recovery_artifact.payload.v1"
      assert manifest["version"] == 1

      assert Map.keys(manifest) |> Enum.sort() ==
               [
                 "applications",
                 "entries",
                 "findings",
                 "profile",
                 "release",
                 "reproducibility",
                 "schema",
                 "source",
                 "toolchain",
                 "version"
               ]

      names = Enum.map(manifest["applications"], & &1["name"])

      assert names == [
               "arbor_kernel",
               "arbor_kernel_runtime",
               "arbor_security",
               "arbor_trust",
               "jason",
               "kernel"
             ]

      classes = Map.new(manifest["applications"], &{&1["name"], &1["class"]})
      assert classes["arbor_trust"] == "selected_first_party"
      assert classes["kernel"] == "runtime"
      assert classes["jason"] == "third_party"
      assert Enum.all?(manifest["applications"], &(&1["start_type"] == "permanent"))

      kinds = Map.new(manifest["entries"], &{&1["path"], &1["content_kind"]})
      assert kinds["lib/arbor_trust-0.1.0/ebin/Elixir.Arbor.Trust.beam"] == "beam"
      assert kinds["lib/arbor_trust-0.1.0/ebin/arbor_trust.app"] == "app_spec"
      assert kinds["releases/0.1.0/arbor_trust.rel"] == "release_metadata"
      assert kinds["bin/erlexec"] == "executable"

      assert manifest["release"]["entry_count"] == length(manifest["entries"])
      assert manifest["release"]["application_count"] == 6
      assert manifest["reproducibility"]["status"] == "identical"
      assert manifest["reproducibility"]["differing_paths"] == []
      assert manifest["reproducibility"]["rule"] == "remove_exact_releases_cookie_before_scan"

      finding_ids = Enum.map(manifest["findings"], & &1["id"])
      assert finding_ids == ["third_party_applications", "unsafe_native_or_executable_ownership"]
      assert Enum.all?(manifest["findings"], &(&1["blocker_owner"] == "p1e_release_separation"))
      assert Enum.all?(manifest["findings"], &(&1["severity"] == "blocker"))
      refute Map.has_key?(hd(manifest["findings"]), "rationale")

      assert :ok = Encode.validate_manifest(manifest)
      assert {:ok, ^manifest} = Core.project(Fixture.load_checked_in_fixture())
    end

    test "ignores map-key and sortable-list reordering" do
      candidate = Fixture.candidate()
      assert {:ok, manifest} = Core.project(candidate)

      reordered = %{
        candidate
        | "source" =>
            candidate["source"]
            |> Map.put("build_inputs", Enum.reverse(candidate["source"]["build_inputs"])),
          "builds" =>
            Enum.map(candidate["builds"], fn snap ->
              %{snap | "term_contents" => Enum.reverse(snap["term_contents"])}
            end)
      }

      assert {:ok, ^manifest} = Core.project(reordered)
    end

    test "frozen profile and E0A literals match SafeRecoveryProfile" do
      {:ok, profile} =
        :arbor_commands
        |> Application.app_dir("priv/packaging/safe_recovery_profile.v1.json")
        |> File.read!()
        |> Jason.decode!()
        |> then(&SafeRecoveryProfile.Core.project/1)

      assert {:ok, digest} = SafeRecoveryProfile.Encode.profile_digest(profile)
      assert digest == Encode.profile_digest_value()
      assert profile["source_inventory"]["selected_file_count"] == Encode.selected_file_count()
      assert profile["source_inventory"]["selected_index_digest"] == Encode.e0a_index_digest()
      assert profile["source_inventory"]["entries_digest"] == Encode.e0a_entries_digest()
      assert profile["source_inventory"]["review_digest"] == Encode.e0a_review_digest()
    end
  end

  describe "project/1 closed candidate" do
    test "rejects locked profile, toolchain, release, and git mismatches" do
      candidate = Fixture.candidate()

      bad_profile = %{candidate["profile"] | "digest" => String.duplicate("0", 64)}

      assert {:error, {:invalid_field, "digest", :digest_mismatch}} =
               Core.project(%{candidate | "profile" => bad_profile})

      bad_toolchain = %{candidate["toolchain"] | "target" => "x86_64-apple-darwin"}

      assert {:error, {:invalid_field, "toolchain", :profile_mismatch}} =
               Core.project(%{candidate | "toolchain" => bad_toolchain})

      bad_release = %{candidate["release"] | "name" => "other"}

      assert {:error, {:invalid_field, "release", :release_mismatch}} =
               Core.project(%{candidate | "release" => bad_release})

      bad_git = %{candidate["source"] | "object_format" => "md5"}

      assert {:error, {:invalid_field, "object_format", :invalid_object_format}} =
               Core.project(%{candidate | "source" => bad_git})

      inventory = %{
        candidate["source"]["platform_inventory"]
        | "review_digest" => String.duplicate("1", 64)
      }

      bad_e0a = %{candidate["source"] | "platform_inventory" => inventory}

      assert {:error, {:invalid_field, "platform_inventory", :digest_mismatch}} =
               Core.project(%{candidate | "source" => bad_e0a})
    end

    test "rejects atom keys, mixed keys, structs, and extra fields" do
      candidate = Fixture.candidate()

      assert {:error, :non_string_keys} = Core.project(%{profile: candidate["profile"]})
      mixed = Map.put(candidate, :profile, candidate["profile"])
      assert {:error, :mixed_keys} = Core.project(mixed)
      assert {:error, :invalid_candidate} = Core.project(Date.utc_today())

      assert {:error, {:field_mismatch, %{extra_count: 1}}} =
               Core.project(Map.put(candidate, "extra", 1))
    end

    test "rejects cookie, missing content, extra content, and hash mismatch" do
      snapshot = Fixture.golden_snapshot()
      cookie = Fixture.add_file(snapshot, "releases/COOKIE", "secret", 0o600)
      assert {:error, :cookie_present} = Core.project(Fixture.candidate(snapshot: cookie))

      missing = %{snapshot | "term_contents" => tl(snapshot["term_contents"])}
      assert {:error, :missing_content} = Core.project(Fixture.candidate(snapshot: missing))

      extra = %{
        snapshot
        | "term_contents" => snapshot["term_contents"] ++ [%{"path" => "x.app", "bytes" => "x"}]
      }

      assert {:error, :extra_content} = Core.project(Fixture.candidate(snapshot: extra))

      [first | rest] = snapshot["term_contents"]
      bytes = first["bytes"]
      last = binary_part(bytes, byte_size(bytes) - 1, 1)
      flip = if last == ".", do: "!", else: "."
      tampered_bytes = binary_part(bytes, 0, byte_size(bytes) - 1) <> flip
      tampered = [%{first | "bytes" => tampered_bytes} | rest]

      assert {:error, :content_digest_mismatch} =
               Core.project(
                 Fixture.candidate(snapshot: %{snapshot | "term_contents" => tampered})
               )
    end

    test "rejects missing selected app, extra spec, and missing required dep" do
      snapshot = Fixture.golden_snapshot()

      without_trust =
        snapshot
        |> drop_path("lib/arbor_trust-0.1.0/ebin/arbor_trust.app")
        |> put_rel(rel_without("arbor_trust"))

      assert {:error, :missing_selected_application} =
               Core.project(Fixture.candidate(snapshot: without_trust))

      extra_app = Fixture.app_body("arbor_shell")

      extra =
        Fixture.add_file(snapshot, "lib/arbor_shell-0.1.0/ebin/arbor_shell.app", extra_app, 0o644)

      extra = put_contents(extra, "lib/arbor_shell-0.1.0/ebin/arbor_shell.app", extra_app)
      assert {:error, :undeclared_app_spec} = Core.project(Fixture.candidate(snapshot: extra))
    end

    test "rejects unsorted inventory and snapshot count errors" do
      snapshot = Fixture.golden_snapshot()
      files = Enum.reverse(snapshot["inventory"]["regular_files"])
      inventory = %{snapshot["inventory"] | "regular_files" => files}
      unsorted = %{snapshot | "inventory" => inventory}
      assert {:error, :inventory_not_sorted} = Core.project(Fixture.candidate(snapshot: unsorted))

      candidate = Fixture.candidate()
      assert {:error, :snapshot_count} = Core.project(%{candidate | "builds" => [snapshot]})
    end

    test "reports changed, added, and removed paths" do
      first = Fixture.golden_snapshot()
      second = Fixture.replace_file(first, "README", "hello", 0o644)
      second = Fixture.add_file(second, "NOTES", "n", 0o644)

      first = Fixture.add_file(first, "README", "hello", 0o644)
      first = Fixture.add_file(first, "GONE", "g", 0o644)

      assert {:ok, manifest} = Core.project(Fixture.candidate(snapshot: first, second: second))
      assert manifest["reproducibility"]["status"] == "different"

      assert manifest["reproducibility"]["differing_paths"] == [
               "GONE",
               "NOTES"
             ]
    end

    test "snapshot order is identity, not invariant" do
      first = Fixture.golden_snapshot()
      second = Fixture.add_file(first, "ONLY_SECOND", "x", 0o644)
      assert {:ok, a} = Core.project(Fixture.candidate(snapshot: first, second: second))
      assert {:ok, b} = Core.project(Fixture.candidate(snapshot: second, second: first))
      refute a["entries"] == b["entries"]
      assert a["reproducibility"]["status"] == "different"
    end

    test "derives owner from exact lib/name-vsn segments and rejects ambiguity" do
      assert {:ok, manifest} = Core.project(Fixture.candidate())
      by_path = Map.new(manifest["entries"], &{&1["path"], &1["owner_application"]})
      assert by_path["lib/arbor_trust-0.1.0/ebin/arbor_trust.app"] == "arbor_trust"
      assert by_path["bin/erlexec"] == nil
      assert by_path["releases/0.1.0/arbor_trust.rel"] == nil

      snapshot =
        Fixture.add_file(
          Fixture.golden_snapshot(),
          "lib/arbor_trust-0.1.0/priv/lib/kernel-1.0.0/x",
          "z",
          0o644
        )

      assert {:error, :ownership_ambiguity} = Core.project(Fixture.candidate(snapshot: snapshot))
    end

    test "rejects a required dependency missing from the release" do
      snapshot = Fixture.golden_snapshot()
      body = Fixture.app_body("arbor_trust") |> String.replace("[kernel]", "[kernel,stdlib]")

      snapshot =
        Fixture.replace_file(snapshot, "lib/arbor_trust-0.1.0/ebin/arbor_trust.app", body, 0o644)

      assert {:error, :missing_dependency} = Core.project(Fixture.candidate(snapshot: snapshot))
    end

    test "admits Mix-shaped optional apps listed in applications but absent from the release" do
      snapshot = Fixture.golden_snapshot()

      body =
        Fixture.app_body("arbor_trust")
        |> String.replace(
          "{applications,[kernel]}",
          "{applications,[kernel,jason]},{optional_applications,[jason]}"
        )

      snapshot =
        Fixture.replace_file(snapshot, "lib/arbor_trust-0.1.0/ebin/arbor_trust.app", body, 0o644)

      assert {:ok, _manifest} = Core.project(Fixture.candidate(snapshot: snapshot))
    end
  end

  describe "inventory ceilings" do
    test "rejects path, component, depth, and byte ceilings" do
      snapshot = Fixture.golden_snapshot()

      long = Fixture.add_file(snapshot, String.duplicate("a", 4097), "x", 0o644)
      assert {:error, :unbounded} = Core.project(Fixture.candidate(snapshot: long))

      deep = Enum.map(1..49, &"d#{&1}") |> Enum.join("/")
      deep_snap = Fixture.add_file(snapshot, deep, "x", 0o644)
      assert {:error, :unbounded} = Core.project(Fixture.candidate(snapshot: deep_snap))
    end

    @tag :slow
    test "rejects 50001 entries and total bytes above 512 MiB" do
      snapshot = Fixture.golden_snapshot()
      inventory = snapshot["inventory"]
      current = inventory["counts"]["entries"]

      extras =
        Enum.map(1..(50_001 - current), fn i -> Fixture.regular_file("z#{i}", "x", 0o644) end)

      files = inventory["regular_files"] ++ extras
      huge = %{snapshot | "inventory" => Fixture.inventory(inventory["directories"], files)}
      assert {:error, :unbounded} = Core.project(Fixture.candidate(snapshot: huge))

      [file | rest] = snapshot["inventory"]["regular_files"]

      oversized = %{
        file
        | "size" => 512 * 1024 * 1024 + 1,
          "prefix_hex" => String.duplicate("aa", 256)
      }

      counts = %{snapshot["inventory"]["counts"] | "total_regular_bytes" => oversized["size"]}

      inv = %{
        snapshot["inventory"]
        | "regular_files" => [oversized | rest],
          "counts" => counts
      }

      assert {:error, :unbounded} =
               Core.project(Fixture.candidate(snapshot: %{snapshot | "inventory" => inv}))
    end
  end

  describe "named constants" do
    test "runtime set includes the forbidden subset" do
      runtime = Encode.runtime_application_names()
      forbidden = Encode.forbidden_runtime_application_names()
      assert MapSet.subset?(forbidden, runtime)
      assert Derive.application_class("os_mon") == "runtime"
      assert Derive.application_class("arbor_shell") == "unexpected_first_party"
      assert Derive.application_class("jason") == "third_party"
    end
  end

  defp drop_path(snapshot, path) do
    inventory = snapshot["inventory"]
    files = Enum.reject(inventory["regular_files"], &(&1["path"] == path))
    contents = Enum.reject(snapshot["term_contents"], &(&1["path"] == path))

    %{
      "inventory" => Fixture.inventory(inventory["directories"], files),
      "term_contents" => contents
    }
  end

  defp put_contents(snapshot, path, bytes) do
    contents =
      snapshot["term_contents"]
      |> Enum.reject(&(&1["path"] == path))
      |> Kernel.++([%{"path" => path, "bytes" => bytes}])
      |> Enum.sort_by(& &1["path"])

    %{snapshot | "term_contents" => contents}
  end

  defp put_rel(snapshot, bytes) do
    Fixture.replace_file(snapshot, "releases/0.1.0/arbor_trust.rel", bytes, 0o644)
  end

  defp rel_without(name) do
    Fixture.rel_body()
    |> String.replace("{#{name},<<\"0.1.0\">>},", "")
  end
end
