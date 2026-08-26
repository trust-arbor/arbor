defmodule Arbor.Shell.OciAdmissionCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.OciAdmissionCore

  @moduletag :fast
  @moduletag :security_regression

  @digest String.duplicate("b", 64)
  @execution "sha256:#{@digest}"
  @image_id "sha256:" <> String.duplicate("1", 64)
  @lock String.duplicate("c", 64)
  @tree String.duplicate("d", 64)

  @labels %{
    "org.arbor.validation.schema" => "1",
    "org.arbor.validation.role" => "spawn-containment",
    "org.arbor.validation.platform" => "linux/amd64",
    "org.arbor.validation.erlang" => "28.4.1",
    "org.arbor.validation.elixir" => "1.19.5-otp-28",
    "org.arbor.validation.mix-lock-sha256" => @lock,
    "org.arbor.validation.deps-tree-sha256" => @tree
  }

  @policy %{
    image: "docker.io/arbor/validation@#{@execution}",
    manifest_digest: @execution,
    labels: @labels,
    mix_lock_digest: @lock,
    baseline_tree_digest: @tree,
    toolchain: %{erlang: "28.4.1", elixir: "1.19.5-otp-28"},
    platform: "linux/amd64"
  }

  @evidence %{
    inspect: %{
      "Digest" => @execution,
      "Labels" => @labels,
      "Architecture" => "amd64",
      "Os" => "linux"
    }
  }

  test "admits a provisioning digest whose sha256 matches inspect" do
    assert {:ok, receipt} = OciAdmissionCore.new(%{policy: @policy, evidence: @evidence})
    assert receipt["execution_image"] == @execution
    assert receipt["platform"] == "linux/amd64"
    assert receipt["driver"] == "podman"
  end

  test "admits a local image id when inspect Digest and labels still match" do
    policy = Map.put(@policy, :image_id, @image_id)
    evidence = put_in(@evidence, [:inspect, "Id"], @image_id)

    assert {:ok, receipt} = OciAdmissionCore.new(%{policy: policy, evidence: evidence})
    assert receipt["execution_image"] == @image_id
  end

  test "security regression: label digest mismatch is rejected" do
    labels = Map.put(@labels, "org.arbor.validation.mix-lock-sha256", String.duplicate("e", 64))
    policy = Map.put(@policy, :labels, labels)

    assert {:error, :fixed_attestation_label_mismatch} =
             OciAdmissionCore.new(%{policy: policy, evidence: @evidence})
  end

  test "security regression: inspect digest mismatch is rejected" do
    evidence = put_in(@evidence, [:inspect, "Digest"], "sha256:" <> String.duplicate("f", 64))

    assert {:error, :execution_digest_mismatch} =
             OciAdmissionCore.new(%{policy: @policy, evidence: evidence})
  end

  test "security regression: tag-shaped policy image is rejected" do
    policy = Map.put(@policy, :image, "arbor/validation:latest")

    assert {:error, :mutable_image_tag} =
             OciAdmissionCore.new(%{policy: policy, evidence: @evidence})
  end

  test "security regression: vminit keys are apple-only and rejected" do
    policy = Map.put(@policy, :vminit_image, "sha256:" <> String.duplicate("a", 64))

    assert {:error, :apple_only_policy_key} =
             OciAdmissionCore.new(%{policy: policy, evidence: @evidence})
  end

  test "security regression: inspect label drift is rejected" do
    evidence =
      put_in(@evidence, [:inspect, "Labels", "org.arbor.validation.platform"], "linux/arm64")

    assert {:error, :inspect_label_mismatch} =
             OciAdmissionCore.new(%{policy: @policy, evidence: evidence})
  end

  test "security regression: image_id cannot skip inspect digest mismatch" do
    policy = Map.put(@policy, :image_id, @image_id)

    evidence =
      @evidence
      |> put_in([:inspect, "Id"], @image_id)
      |> put_in([:inspect, "Digest"], "sha256:" <> String.duplicate("f", 64))

    assert {:error, :execution_digest_mismatch} =
             OciAdmissionCore.new(%{policy: policy, evidence: evidence})
  end

  test "security regression: image_id mismatch is rejected" do
    policy = Map.put(@policy, :image_id, @image_id)
    evidence = put_in(@evidence, [:inspect, "Id"], "sha256:" <> String.duplicate("2", 64))

    assert {:error, :image_id_mismatch} =
             OciAdmissionCore.new(%{policy: policy, evidence: evidence})
  end

  test "security regression: image_id without inspect Id is rejected" do
    policy = Map.put(@policy, :image_id, @image_id)

    assert {:error, :missing_inspect_id} =
             OciAdmissionCore.new(%{policy: policy, evidence: @evidence})
  end

  test "security regression: inspect Digest must match policy manifest_digest" do
    policy = Map.put(@policy, :manifest_digest, "sha256:" <> String.duplicate("f", 64))

    assert {:error, :manifest_digest_mismatch} =
             OciAdmissionCore.new(%{policy: policy, evidence: @evidence})
  end
end
