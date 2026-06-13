defmodule Arbor.Orchestrator.Eval.RunIdentityTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Eval.RunIdentity

  describe "capture/1" do
    test "adds git_sha and git_dirty when running inside a git repo" do
      attrs = RunIdentity.capture(%{id: "run1"})

      # In CI/dev this runs inside the arbor repo; if git is somehow
      # unavailable the fields are simply absent (fail-safe), so only
      # assert shape when present.
      case attrs[:git_sha] do
        nil -> refute Map.has_key?(attrs, :git_sha)
        sha -> assert sha =~ ~r/^[0-9a-f]{40}$/
      end

      case attrs[:git_dirty] do
        nil -> refute Map.has_key?(attrs, :git_dirty)
        dirty -> assert is_boolean(dirty)
      end
    end

    test "never overwrites caller-provided values" do
      attrs =
        RunIdentity.capture(%{
          git_sha: "caller-sha",
          git_dirty: true,
          dataset_hash: "caller-hash",
          config_fingerprint: "caller-fp",
          config: %{a: 1},
          dataset: "nonexistent.jsonl"
        })

      assert attrs[:git_sha] == "caller-sha"
      assert attrs[:git_dirty] == true
      assert attrs[:dataset_hash] == "caller-hash"
      assert attrs[:config_fingerprint] == "caller-fp"
    end

    test "omits dataset_hash for missing dataset path" do
      attrs = RunIdentity.capture(%{dataset: "definitely/not/a/file.jsonl"})
      refute Map.has_key?(attrs, :dataset_hash)
    end

    test "omits dataset_hash when dataset key absent" do
      attrs = RunIdentity.capture(%{id: "run1"})
      refute Map.has_key?(attrs, :dataset_hash)
    end
  end

  describe "dataset_hash/1" do
    @tag :tmp_dir
    test "hashes file contents deterministically and detects edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dataset.jsonl")
      File.write!(path, ~s({"input": "a", "expected": "b"}\n))

      hash1 = RunIdentity.dataset_hash(path)
      hash2 = RunIdentity.dataset_hash(path)
      assert hash1 == hash2
      assert hash1 =~ ~r/^sha256:[0-9a-f]{64}$/

      # An edited dataset must produce a different hash — this is the
      # "dataset edits silently invalidate comparisons" guard.
      File.write!(path, ~s({"input": "a", "expected": "CHANGED"}\n))
      assert RunIdentity.dataset_hash(path) != hash1
    end

    test "nil and missing paths return nil" do
      assert RunIdentity.dataset_hash(nil) == nil
      assert RunIdentity.dataset_hash("no/such/file.jsonl") == nil
      assert RunIdentity.dataset_hash(123) == nil
    end
  end

  describe "config_fingerprint/1" do
    test "deterministic regardless of construction order" do
      a = %{timeout: 60, stream: true, model: "x"}
      b = %{model: "x", stream: true, timeout: 60}
      assert RunIdentity.config_fingerprint(a) == RunIdentity.config_fingerprint(b)
      assert RunIdentity.config_fingerprint(a) =~ ~r/^sha256:[0-9a-f]{64}$/
    end

    test "different configs produce different fingerprints" do
      refute RunIdentity.config_fingerprint(%{timeout: 60}) ==
               RunIdentity.config_fingerprint(%{timeout: 61})
    end

    test "nil and empty return nil" do
      assert RunIdentity.config_fingerprint(nil) == nil
      assert RunIdentity.config_fingerprint(%{}) == nil
      assert RunIdentity.config_fingerprint("not a map") == nil
    end
  end
end
