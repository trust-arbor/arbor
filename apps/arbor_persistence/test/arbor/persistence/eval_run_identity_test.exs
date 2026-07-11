defmodule Arbor.Persistence.EvalRunIdentityTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence

  describe "capture_eval_run_identity/1" do
    test "adds git_sha and git_dirty when running inside a git repo" do
      attrs = Persistence.capture_eval_run_identity(%{id: "run1"})

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
        Persistence.capture_eval_run_identity(%{
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
      attrs = Persistence.capture_eval_run_identity(%{dataset: "definitely/not/a/file.jsonl"})
      refute Map.has_key?(attrs, :dataset_hash)
    end

    test "omits dataset_hash when dataset key absent" do
      attrs = Persistence.capture_eval_run_identity(%{id: "run1"})
      refute Map.has_key?(attrs, :dataset_hash)
    end
  end

  describe "eval_dataset_hash/1" do
    @tag :tmp_dir
    test "hashes file contents deterministically and detects edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dataset.jsonl")
      File.write!(path, ~s({"input": "a", "expected": "b"}\n))

      hash1 = Persistence.eval_dataset_hash(path)
      hash2 = Persistence.eval_dataset_hash(path)
      assert hash1 == hash2
      assert hash1 =~ ~r/^sha256:[0-9a-f]{64}$/

      File.write!(path, ~s({"input": "a", "expected": "CHANGED"}\n))
      assert Persistence.eval_dataset_hash(path) != hash1
    end

    test "nil and missing paths return nil" do
      assert Persistence.eval_dataset_hash(nil) == nil
      assert Persistence.eval_dataset_hash("no/such/file.jsonl") == nil
      assert Persistence.eval_dataset_hash(123) == nil
    end
  end

  describe "eval_config_fingerprint/1" do
    test "deterministic regardless of construction order" do
      a = %{timeout: 60, stream: true, model: "x"}
      b = %{model: "x", stream: true, timeout: 60}
      assert Persistence.eval_config_fingerprint(a) == Persistence.eval_config_fingerprint(b)
      assert Persistence.eval_config_fingerprint(a) =~ ~r/^sha256:[0-9a-f]{64}$/
    end

    test "different configs produce different fingerprints" do
      refute Persistence.eval_config_fingerprint(%{timeout: 60}) ==
               Persistence.eval_config_fingerprint(%{timeout: 61})
    end

    test "nil and empty return nil" do
      assert Persistence.eval_config_fingerprint(nil) == nil
      assert Persistence.eval_config_fingerprint(%{}) == nil
      assert Persistence.eval_config_fingerprint("not a map") == nil
    end
  end
end
