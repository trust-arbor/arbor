defmodule Arbor.Commands.SafeRecoveryArtifact.CheckCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.{CheckCore, Encode, Envelope}
  alias Arbor.Commands.TwoBuildFactFixture, as: TB

  @moduletag :fast

  setup_all do
    {:ok, manifest} =
      Arbor.Commands.SafeRecoveryArtifact.compose_from_facts_for_test(%{
        mode: :compose,
        facts: TB.facts()
      })

    {:ok, payload_bytes} = Encode.encode_manifest(manifest)
    {:ok, envelope} = Envelope.build(payload_bytes)
    %{manifest: manifest, envelope: envelope, payload_bytes: payload_bytes}
  end

  describe "admit_artifact/1 (report level)" do
    test "admits the closed envelope plus fully validated payload", ctx do
      assert {:ok, %{envelope: envelope, manifest: manifest}} =
               CheckCore.admit_artifact(%{envelope_map: ctx.envelope, manifest_map: ctx.manifest})

      assert envelope == ctx.envelope
      assert manifest == ctx.manifest
    end

    test "a different-but-still-valid reproducibility status is admitted at report level", ctx do
      repro = %{
        ctx.manifest["reproducibility"]
        | "payload_tree_digests" => [
            hd(ctx.manifest["reproducibility"]["payload_tree_digests"]),
            String.duplicate("c", 64)
          ]
      }

      different = %{ctx.manifest | "reproducibility" => Map.put(repro, "status", "different")}
      assert :ok = Encode.validate_manifest(different)

      assert {:ok, _} =
               CheckCore.admit_artifact(%{envelope_map: ctx.envelope, manifest_map: different})
    end

    test "findings tamper fails closed with a derived mismatch (blocker-set exactness)", ctx do
      [finding | rest] = ctx.manifest["findings"]
      tampered = %{ctx.manifest | "findings" => [%{finding | "severity" => "info"} | rest]}

      assert {:error, {:invalid_field, "severity", :derived_mismatch}} =
               CheckCore.admit_artifact(%{envelope_map: ctx.envelope, manifest_map: tampered})
    end

    test "envelope and manifest shape failures fail closed", ctx do
      assert {:error, _} =
               CheckCore.admit_artifact(%{envelope_map: :not_a_map, manifest_map: ctx.manifest})

      assert {:error, _} =
               CheckCore.admit_artifact(%{envelope_map: ctx.envelope, manifest_map: %{}})

      assert {:error, :invalid_artifact} = CheckCore.admit_artifact(:not_a_map)
    end
  end

  describe "admit_for_check/1 (check level)" do
    test "rejects a non-identical reproducibility result", ctx do
      different = %{ctx.manifest | "reproducibility" => put_status(ctx.manifest, "different")}
      assert :ok = Encode.validate_manifest(different)

      assert {:error, :reproducibility_mismatch} =
               CheckCore.admit_for_check(%{envelope_map: ctx.envelope, manifest_map: different})
    end

    test "rejects a mix.lock digest that disagrees with the build inputs", ctx do
      toolchain = %{ctx.manifest["toolchain"] | "mix_lock_sha256" => String.duplicate("e", 64)}
      tampered = %{ctx.manifest | "toolchain" => toolchain}
      assert :ok = Encode.validate_manifest(tampered)

      assert {:error, :lock_binding_mismatch} =
               CheckCore.admit_for_check(%{envelope_map: ctx.envelope, manifest_map: tampered})
    end

    test "rejects a .tool-versions digest that disagrees with the build inputs", ctx do
      toolchain = %{
        ctx.manifest["toolchain"]
        | "tool_versions_sha256" => String.duplicate("f", 64)
      }

      tampered = %{ctx.manifest | "toolchain" => toolchain}
      assert :ok = Encode.validate_manifest(tampered)

      assert {:error, :lock_binding_mismatch} =
               CheckCore.admit_for_check(%{envelope_map: ctx.envelope, manifest_map: tampered})
    end

    test "admits the conformant identical evidence", ctx do
      assert {:ok, _} =
               CheckCore.admit_for_check(%{
                 envelope_map: ctx.envelope,
                 manifest_map: ctx.manifest
               })
    end
  end

  describe "compare_inputs/2 (complete input binding)" do
    test "equal inputs admit" do
      inputs = [%{"path" => "mix.lock", "sha256" => digest(1)}]
      assert :ok = CheckCore.compare_inputs(inputs, inputs)
    end

    test "a count difference fails closed with the counts" do
      committed = [%{"path" => "a", "sha256" => digest(1)}]

      observed = [
        %{"path" => "a", "sha256" => digest(1)},
        %{"path" => "b", "sha256" => digest(2)}
      ]

      assert {:error, {:input_count_mismatch, 1, 2}} =
               CheckCore.compare_inputs(committed, observed)
    end

    test "a missing observed input fails closed naming the path" do
      committed = [
        %{"path" => "mix.lock", "sha256" => digest(1)},
        %{"path" => ".tool-versions", "sha256" => digest(2)}
      ]

      observed = [
        %{"path" => "mix.lock", "sha256" => digest(1)},
        %{"path" => "other", "sha256" => digest(3)}
      ]

      assert {:error, {:missing_build_input, ".tool-versions"}} =
               CheckCore.compare_inputs(committed, observed)
    end

    test "a path-set swap at equal count fails closed naming the dropped input" do
      # With the count guard first, a same-count swap always surfaces as a
      # missing committed input; the extra branch is defense in depth for a
      # violated count invariant and is not independently reachable.
      committed = [
        %{"path" => "mix.lock", "sha256" => digest(1)},
        %{"path" => ".tool-versions", "sha256" => digest(2)}
      ]

      observed = [
        %{"path" => "mix.lock", "sha256" => digest(1)},
        %{"path" => "apps/arbor_trust/lib/ghost.ex", "sha256" => digest(3)}
      ]

      assert {:error, {:missing_build_input, ".tool-versions"}} =
               CheckCore.compare_inputs(committed, observed)
    end

    test "a per-path digest mismatch fails closed naming the path" do
      committed = [%{"path" => "mix.lock", "sha256" => digest(1)}]
      observed = [%{"path" => "mix.lock", "sha256" => digest(2)}]

      assert {:error, {:input_digest_mismatch, "mix.lock"}} =
               CheckCore.compare_inputs(committed, observed)
    end

    test "non-list shapes fail closed" do
      assert {:error, :invalid_inputs} = CheckCore.compare_inputs(:a, [])
      assert {:error, :invalid_inputs} = CheckCore.compare_inputs([], :b)
    end
  end

  defp put_status(manifest, status) do
    %{manifest["reproducibility"] | "status" => status}
  end

  defp digest(byte) when is_integer(byte) do
    :crypto.hash(:sha256, <<byte>>) |> Base.encode16(case: :lower)
  end
end
