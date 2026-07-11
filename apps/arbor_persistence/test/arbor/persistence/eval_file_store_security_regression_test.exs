defmodule Arbor.Persistence.EvalFileStoreSecurityRegressionTest do
  @moduledoc """
  Security regression tests for eval file-store hardening.

  Exercised exclusively through the public `Arbor.Persistence` facade.
  These tests must FAIL against the ownership-extraction parent commit and
  PASS after the hardening commit.
  """
  use ExUnit.Case, async: true
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Persistence

  setup do
    base = Path.join(System.tmp_dir!(), "eval_sec_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "store")
    outside = Path.join(base, "outside")
    File.mkdir_p!(dir)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(base) end)
    %{dir: dir, outside: outside, base: base}
  end

  # ---------------------------------------------------------------------------
  # Run ID validation / traversal
  # ---------------------------------------------------------------------------

  describe "security regression: invalid run ids" do
    test "rejects path traversal run ids on write", %{dir: dir, outside: outside} do
      marker = Path.join(outside, "pwned.json")
      refute File.exists?(marker)

      for bad_id <- [
            "../outside/pwned",
            "..%2foutside%2fpwned",
            "foo/../outside/pwned",
            "/tmp/absolute",
            "has\\backslash",
            "has/slash",
            "nul\x00byte",
            "percent%2e%2e",
            ".",
            "..",
            String.duplicate("a", 200)
          ] do
        assert {:error, :invalid_run_id} =
                 Persistence.save_eval_run_file(bad_id, %{model: "m"}, dir: dir),
               "expected reject for #{inspect(bad_id)}"
      end

      refute File.exists?(marker)
      # Store dir must not gain traversal-named files either
      assert File.ls!(dir) == []
    end

    test "rejects path traversal run ids on read", %{dir: dir} do
      assert {:error, :invalid_run_id} =
               Persistence.load_eval_run_file("../etc/passwd", dir: dir)

      assert {:error, :invalid_run_id} =
               Persistence.load_eval_run_file("..%2fetc%2fpasswd", dir: dir)
    end

    test "outside files are not modified by rejected writes", %{dir: dir, outside: outside} do
      victim = Path.join(outside, "keep-me.txt")
      File.write!(victim, "original")

      assert {:error, :invalid_run_id} =
               Persistence.save_eval_run_file(
                 "../outside/keep-me.txt",
                 %{model: "attacker", payload: "owned"},
                 dir: dir
               )

      assert File.read!(victim) == "original"
    end
  end

  describe "security regression: generated run ids" do
    test "generated ids are always valid filename components" do
      for {model, domain} <- [
            {"openai/gpt-4o:latest", "coding"},
            {"../../../etc", "passwd"},
            {"a%2e%2e", "b/c"},
            {String.duplicate("M", 300), String.duplicate("D", 300)},
            {"UPPER.Model", "Domain_Name"}
          ] do
        id = Persistence.generate_eval_run_id(model, domain)
        assert is_binary(id)
        refute String.contains?(id, "/")
        refute String.contains?(id, "\\")
        refute String.contains?(id, "%")
        refute String.contains?(id, "..")
        assert byte_size(id) <= 128
        assert id == String.downcase(id)
      end
    end

    test "generated ids can be written under a store dir", %{dir: dir} do
      id = Persistence.generate_eval_run_id("openai/gpt-4o:latest", "coding/../x")
      assert :ok = Persistence.save_eval_run_file(id, %{model: "m", metrics: %{}}, dir: dir)
      assert {:ok, loaded} = Persistence.load_eval_run_file(id, dir: dir)
      assert loaded["id"] == id
    end
  end

  # ---------------------------------------------------------------------------
  # Symlinks
  # ---------------------------------------------------------------------------

  describe "security regression: symlink handling" do
    test "refuses to follow symlink when loading a run", %{dir: dir, outside: outside} do
      secret = Path.join(outside, "secret.json")
      File.write!(secret, ~s({"id":"secret","model":"leaked"}))

      link = Path.join(dir, "run-link.json")
      File.ln_s!(secret, link)

      assert {:error, reason} = Persistence.load_eval_run_file("run-link", dir: dir)
      assert reason in [:symlink_target, :not_a_regular_file, {:file_error, :enoent}]
    end

    test "list skips symlink entries (does not follow)", %{dir: dir, outside: outside} do
      :ok =
        Persistence.save_eval_run_file(
          "real-run",
          %{model: "ok", timestamp: "2026-01-02T00:00:00Z"},
          dir: dir
        )

      secret = Path.join(outside, "secret.json")
      File.write!(secret, ~s({"id":"secret","model":"leaked","timestamp":"2026-01-03T00:00:00Z"}))
      File.ln_s!(secret, Path.join(dir, "symlink-run.json"))

      assert {:ok, runs} = Persistence.list_eval_run_files(dir: dir)
      ids = Enum.map(runs, & &1["id"])
      assert "real-run" in ids
      refute "secret" in ids
      refute "symlink-run" in ids
    end

    test "refuses write when target path is a symlink", %{dir: dir, outside: outside} do
      target = Path.join(outside, "escape.json")
      File.write!(target, ~s({"id":"old"}))
      File.ln_s!(target, Path.join(dir, "escape-run.json"))

      assert {:error, :symlink_target} =
               Persistence.save_eval_run_file(
                 "escape-run",
                 %{model: "attacker", payload: "new"},
                 dir: dir
               )

      assert File.read!(target) == ~s({"id":"old"})
    end

    test "refuses store root that is a symlink", %{base: base, outside: outside} do
      real = Path.join(outside, "real-store")
      File.mkdir_p!(real)
      link_root = Path.join(base, "link-root")
      File.ln_s!(real, link_root)

      assert {:error, :symlink_root} =
               Persistence.save_eval_run_file("r1", %{model: "m"}, dir: link_root)
    end
  end

  # ---------------------------------------------------------------------------
  # Atomic overwrite + hard-link witness
  # ---------------------------------------------------------------------------

  describe "security regression: atomic hard-link overwrite" do
    test "overwrite replaces path content while hard-link witness retains old inode", %{dir: dir} do
      assert :ok =
               Persistence.save_eval_run_file(
                 "atomic-run",
                 %{model: "m", generation: 1, blob: "old-content"},
                 dir: dir
               )

      path = Path.join(dir, "atomic-run.json")
      witness = Path.join(dir, "atomic-run.witness")
      # Hard link to old inode
      File.ln!(path, witness)

      old_via_witness = File.read!(witness)

      assert :ok =
               Persistence.save_eval_run_file(
                 "atomic-run",
                 %{model: "m", generation: 2, blob: "new-content"},
                 dir: dir
               )

      new_via_path = File.read!(path)
      still_old = File.read!(witness)

      assert still_old == old_via_witness
      assert String.contains?(still_old, "old-content")
      assert String.contains?(new_via_path, "new-content")
      refute String.contains?(new_via_path, "old-content")
    end
  end

  # ---------------------------------------------------------------------------
  # Bounds
  # ---------------------------------------------------------------------------

  describe "security regression: size bounds" do
    test "rejects per-file encode over max_file_bytes", %{dir: dir} do
      huge = String.duplicate("x", 2_000)
      # Tiny bound
      assert {:error, :max_file_bytes_exceeded} =
               Persistence.save_eval_run_file(
                 "big-run",
                 %{model: "m", blob: huge},
                 dir: dir,
                 max_file_bytes: 200
               )
    end

    test "rejects load when file exceeds max_file_bytes", %{dir: dir} do
      # Write with a large allowed budget, then load with a tiny budget
      assert :ok =
               Persistence.save_eval_run_file(
                 "sized-run",
                 %{model: "m", blob: String.duplicate("y", 500)},
                 dir: dir,
                 max_file_bytes: 50_000
               )

      assert {:error, :max_file_bytes_exceeded} =
               Persistence.load_eval_run_file("sized-run", dir: dir, max_file_bytes: 50)
    end

    test "list stops on file-count bound", %{dir: dir} do
      for i <- 1..5 do
        assert :ok =
                 Persistence.save_eval_run_file(
                   "count-#{i}",
                   %{model: "m", timestamp: "2026-01-0#{i}T00:00:00Z"},
                   dir: dir
                 )
      end

      assert {:error, :max_files_exceeded} =
               Persistence.list_eval_run_files(dir: dir, max_files: 3)
    end

    test "list stops on aggregate byte bound", %{dir: dir} do
      blob = String.duplicate("z", 400)

      for i <- 1..4 do
        assert :ok =
                 Persistence.save_eval_run_file(
                   "agg-#{i}",
                   %{model: "m", blob: blob, timestamp: "2026-01-0#{i}T00:00:00Z"},
                   dir: dir,
                   max_file_bytes: 10_000
                 )
      end

      assert {:error, :max_total_bytes_exceeded} =
               Persistence.list_eval_run_files(
                 dir: dir,
                 max_file_bytes: 10_000,
                 max_total_bytes: 500
               )
    end

    test "system ceilings clamp unbounded caller opts", %{dir: dir} do
      # Requesting absurd max_files still cannot exceed the hard ceiling;
      # writing a few files succeeds under a huge requested max_files.
      assert :ok =
               Persistence.save_eval_run_file("ceil-1", %{model: "m"}, dir: dir)

      assert {:ok, runs} =
               Persistence.list_eval_run_files(dir: dir, max_files: 10_000_000)

      assert length(runs) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid UTF-8 / JSON
  # ---------------------------------------------------------------------------

  describe "security regression: invalid content handling" do
    test "rejects invalid UTF-8 on load", %{dir: dir} do
      path = Path.join(dir, "bad-utf8.json")
      # Valid run id filename, invalid UTF-8 body
      File.write!(path, <<0xFF, 0xFE, "{}">>)

      assert {:error, :invalid_utf8} = Persistence.load_eval_run_file("bad-utf8", dir: dir)
    end

    test "rejects invalid JSON on load", %{dir: dir} do
      path = Path.join(dir, "bad-json.json")
      File.write!(path, "not-json{")

      assert {:error, {:decode_error, _}} = Persistence.load_eval_run_file("bad-json", dir: dir)
    end
  end

  # ---------------------------------------------------------------------------
  # create_eval_run file backend propagates failures (no false success)
  # ---------------------------------------------------------------------------

  describe "security regression: no false success on file failures" do
    test "create_eval_run with invalid id returns error (file backend)", %{dir: dir} do
      assert {:error, :invalid_run_id} =
               Persistence.create_eval_run(
                 %{
                   id: "../escape",
                   model: "m",
                   domain: "coding",
                   provider: "p",
                   dataset: "d.jsonl"
                 },
                 backend: :file,
                 dir: dir
               )
    end
  end
end
