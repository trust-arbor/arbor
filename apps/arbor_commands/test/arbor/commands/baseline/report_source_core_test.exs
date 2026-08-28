defmodule Arbor.Commands.Baseline.ReportSourceCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.Baseline.ReportSourceCore
  alias Arbor.Commands.Baseline.StatusCore

  @moduletag :fast

  @digest String.duplicate("ab", 32)
  @other String.duplicate("cd", 32)

  defp local_obs do
    %{
      runtime: %{"state" => "unavailable", "driver" => "unavailable", "reason" => "cold"},
      baseline: %{"state" => "unavailable", "reason" => "cold"},
      mix_lock_digest: {:error, :linux_dependency_baseline_unavailable},
      head_mix_lock_digest: @digest,
      probe: {:error, :image_policy_unavailable},
      host_platform: "x86_64-pc-linux-gnu",
      guest_platform: "linux/amd64"
    }
  end

  defp node_obs do
    %{
      runtime: %{"state" => "pinned", "driver" => "podman", "reason" => nil},
      baseline: %{"state" => "pinned", "reason" => nil},
      mix_lock_digest: {:ok, @digest},
      probe: {:ok, %{"state" => "available", "driver" => "podman"}}
    }
  end

  test "node-reachable trusts node runtime, baseline, mix.lock, and probe" do
    decision =
      %{reachability: :reachable, local: local_obs(), node: node_obs()}
      |> ReportSourceCore.new()
      |> ReportSourceCore.decide()
      |> ReportSourceCore.show()

    assert decision.source == "node"
    assert decision.input.runtime["state"] == "pinned"
    assert decision.input.baseline["state"] == "pinned"
    assert decision.input.mix_lock_digest == {:ok, @digest}
    assert decision.input.probe == {:ok, %{"state" => "available", "driver" => "podman"}}
    assert decision.input.head_mix_lock_digest == @digest
    assert decision.input.host_platform == "x86_64-pc-linux-gnu"

    report = StatusCore.project(decision.input)
    assert report["driver"] == "podman"
    assert report["image_reachable"] == true
    assert report["mix_lock_matches_head"] == true
  end

  test "node-unreachable keeps local observations" do
    decision =
      %{reachability: :unreachable, local: local_obs()}
      |> ReportSourceCore.new()
      |> ReportSourceCore.decide()

    assert decision.source == "local (node not running)"
    assert decision.input == local_obs()

    report = StatusCore.project(decision.input)
    assert report["image_reachable"] == false
    assert report["mix_lock_matches_head"] == false
  end

  test "node-error falls back to local and keeps the reason" do
    decision =
      %{reachability: {:error, :nodedown}, local: local_obs()}
      |> ReportSourceCore.new()
      |> ReportSourceCore.decide()

    assert decision.source == "local (nodedown)"
    assert decision.input == local_obs()
    assert decision.input.mix_lock_digest == {:error, :linux_dependency_baseline_unavailable}
  end

  test "node-reachable with missing node observations falls back to local" do
    decision =
      %{reachability: :reachable, local: local_obs(), node: nil}
      |> ReportSourceCore.new()
      |> ReportSourceCore.decide()

    assert decision.source == "local (invalid_node_observations)"
    assert decision.input == local_obs()
  end

  test "node overlay does not replace local head digest or platforms" do
    node = Map.put(node_obs(), :head_mix_lock_digest, @other)

    decision =
      ReportSourceCore.decide(%{
        reachability: :reachable,
        local: local_obs(),
        node: node
      })

    assert decision.input.head_mix_lock_digest == @digest
    assert decision.input.guest_platform == "linux/amd64"
  end
end
