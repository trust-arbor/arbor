defmodule Arbor.Persistence.EvalRunIdentityTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  @exclusive_mkdir_retries 16

  alias Arbor.Persistence
  import Bitwise

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
    test "hashes file contents deterministically and detects edits" do
      tmp_dir = exclusive_owned_temp_dir!("eval_run_identity_")
      on_exit(fn -> File.rm_rf(tmp_dir) end)
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

    test "rejects over-depth nested maps (system ceiling)" do
      deep =
        Enum.reduce(1..40, "leaf", fn _, acc ->
          %{"n" => acc}
        end)

      assert Persistence.eval_config_fingerprint(deep) == nil
    end

    test "rejects oversized string values (system ceiling)" do
      assert Persistence.eval_config_fingerprint(%{blob: String.duplicate("z", 1_100_000)}) ==
               nil
    end

    test "rejects atom/string key collisions" do
      colliding = Map.merge(%{k: 1}, %{"k" => 2})
      assert Persistence.eval_config_fingerprint(colliding) == nil
    end

    test "security regression: rejects a very large integer before JSON encoding" do
      very_large = 1 <<< 1_000_000
      assert Persistence.eval_config_fingerprint(%{value: very_large}) == nil
    end

    test "integer bit-size boundaries remain stable" do
      assert Persistence.eval_config_fingerprint(%{value: 1 <<< 999_999}) =~
               ~r/^sha256:[0-9a-f]{64}$/

      assert Persistence.eval_config_fingerprint(%{value: 1 <<< 1_000_000}) == nil
      assert Persistence.eval_config_fingerprint(%{value: -(1 <<< 1_000_000)}) == nil
    end

    test "security regression: wide shallow sibling nesting remains valid" do
      config =
        Map.new(1..1_000, fn index ->
          {"sibling-#{index}", %{"nested" => [index, %{"enabled" => true}]}}
        end)

      fingerprint = Persistence.eval_config_fingerprint(config)
      assert fingerprint =~ ~r/^sha256:[0-9a-f]{64}$/
      assert Persistence.eval_config_fingerprint(config) == fingerprint
    end

    test "handles finite float extremes without raising" do
      assert Persistence.eval_config_fingerprint(%{min: -1.7976931348623157e308, zero: -0.0}) =~
               ~r/^sha256:[0-9a-f]{64}$/
    end

    test "security regression: accepts 21,000 bounded integers below 1 MiB" do
      integers = Enum.map(1..21_000, &((1 <<< 127) + &1))
      assert byte_size(Jason.encode!(%{values: integers})) == 840_012

      assert Persistence.eval_config_fingerprint(%{values: integers}) =~
               ~r/^sha256:[0-9a-f]{64}$/
    end

    test "security regression: accepts 10,000 bounded ASCII keys below 1 MiB" do
      config =
        Map.new(0..9_999, fn index ->
          {"key-" <> String.pad_leading(Integer.to_string(index), 12, "0"), true}
        end)

      assert byte_size(Jason.encode!(config)) == 240_001
      assert Persistence.eval_config_fingerprint(config) =~ ~r/^sha256:[0-9a-f]{64}$/
    end
  end

  defp exclusive_owned_temp_dir!(prefix) do
    Enum.reduce_while(1..@exclusive_mkdir_retries, :error, fn _, _ ->
      path =
        Path.join(
          System.tmp_dir!(),
          prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        )

      case File.mkdir(path) do
        :ok ->
          File.chmod!(path, 0o700)
          {:halt, path}

        {:error, :eexist} ->
          {:cont, :error}

        {:error, _} ->
          {:cont, :error}
      end
    end)
    |> case do
      path when is_binary(path) -> path
      :error -> flunk("could not allocate exclusive temp directory")
    end
  end
end
