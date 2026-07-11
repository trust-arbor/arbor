defmodule Arbor.Persistence.EvalFileStoreSecurityRegressionTest do
  @moduledoc """
  Security regression tests for eval file-store hardening.

  Exercised exclusively through the public `Arbor.Persistence` facade.
  These tests must FAIL against the ownership-extraction parent commit
  (`07de3232`) and PASS after hardening.

  Each assertion group is independent so an earlier failure does not mask
  a later security claim.
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
  # Budgeted encode (depth / nodes / strings / duplicate keys)
  # ---------------------------------------------------------------------------

  describe "security regression: budgeted encode before materialization" do
    test "rejects per-file encode over max_file_bytes without leaving a file", %{dir: dir} do
      huge = String.duplicate("x", 2_000)

      assert {:error, :max_file_bytes_exceeded} =
               Persistence.save_eval_run_file(
                 "big-run",
                 %{model: "m", blob: huge},
                 dir: dir,
                 max_file_bytes: 200
               )

      refute File.exists?(Path.join(dir, "big-run.json"))
    end

    test "rejects atom/string key alias collisions on save", %{dir: dir} do
      data = Map.merge(%{model: "atom-model"}, %{"model" => "string-model"})

      assert {:error, :duplicate_json_key} =
               Persistence.save_eval_run_file("dup-key-run", data, dir: dir)

      refute File.exists?(Path.join(dir, "dup-key-run.json"))
    end

    test "persists exactly one string id and timestamp (no dual-key ambiguity)", %{dir: dir} do
      # Matching atom/string aliases are collapsed; filename wins for id.
      data =
        %{}
        |> Map.put(:id, "caller-id")
        |> Map.put("id", "caller-id")
        |> Map.put(:model, "m")
        |> Map.put(:timestamp, "2026-06-01T00:00:00Z")
        |> Map.put("timestamp", "2026-06-01T00:00:00Z")

      assert :ok =
               Persistence.save_eval_run_file("single-id-run", data, dir: dir)

      raw = File.read!(Path.join(dir, "single-id-run.json"))
      # Only one "id" key in the JSON object text (not two adjacent id fields)
      assert length(Regex.scan(~r/"id"\s*:/, raw)) == 1
      assert length(Regex.scan(~r/"timestamp"\s*:/, raw)) == 1

      assert {:ok, loaded} = Persistence.load_eval_run_file("single-id-run", dir: dir)
      assert loaded["id"] == "single-id-run"
      assert loaded["timestamp"] == "2026-06-01T00:00:00Z"
    end

    test "rejects conflicting dual id values on save", %{dir: dir} do
      data =
        %{}
        |> Map.put(:id, "atom-id")
        |> Map.put("id", "string-id")

      assert {:error, :duplicate_json_key} =
               Persistence.save_eval_run_file("conflict-id", data, dir: dir)
    end

    test "rejects excessive encode nesting depth", %{dir: dir} do
      deep =
        Enum.reduce(1..40, "leaf", fn _, acc ->
          %{"n" => acc}
        end)

      assert {:error, :max_encode_depth_exceeded} =
               Persistence.save_eval_run_file("deep-run", deep, dir: dir, max_file_bytes: 100_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Load / list id binding
  # ---------------------------------------------------------------------------

  describe "security regression: bind decoded id to filename run_id" do
    test "load rejects file whose JSON id does not match filename", %{dir: dir} do
      path = Path.join(dir, "filename-run.json")
      File.write!(path, ~s({"id":"other-run","model":"m","timestamp":"2026-01-01T00:00:00Z"}))

      assert {:error, :run_id_mismatch} =
               Persistence.load_eval_run_file("filename-run", dir: dir)
    end

    test "load rejects file missing id field", %{dir: dir} do
      path = Path.join(dir, "no-id-run.json")
      File.write!(path, ~s({"model":"m","timestamp":"2026-01-01T00:00:00Z"}))

      assert {:error, :run_id_mismatch} =
               Persistence.load_eval_run_file("no-id-run", dir: dir)
    end

    test "list skips mismatched ids and keeps matching ones", %{dir: dir} do
      assert :ok =
               Persistence.save_eval_run_file(
                 "good-run",
                 %{model: "ok", timestamp: "2026-01-02T00:00:00Z"},
                 dir: dir
               )

      File.write!(
        Path.join(dir, "spoof-run.json"),
        ~s({"id":"good-run","model":"spoof","timestamp":"2026-01-03T00:00:00Z"})
      )

      assert {:ok, runs} = Persistence.list_eval_run_files(dir: dir)
      ids = Enum.map(runs, & &1["id"])
      assert ids == ["good-run"]
      refute "spoof-run" in ids
    end

    test "list ordering uses bounded string timestamps only", %{dir: dir} do
      assert :ok =
               Persistence.save_eval_run_file(
                 "older",
                 %{model: "m", timestamp: "2026-01-01T00:00:00Z"},
                 dir: dir
               )

      assert :ok =
               Persistence.save_eval_run_file(
                 "newer",
                 %{model: "m", timestamp: "2026-01-02T00:00:00Z"},
                 dir: dir
               )

      assert {:ok, runs} = Persistence.list_eval_run_files(dir: dir, model: "m")
      assert Enum.map(runs, & &1["id"]) == ["newer", "older"]
    end
  end

  # ---------------------------------------------------------------------------
  # Bounds (file bytes, enumeration max_files, aggregate)
  # ---------------------------------------------------------------------------

  describe "security regression: size and enumeration bounds" do
    test "rejects load when file exceeds max_file_bytes", %{dir: dir} do
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

    test "list stops on file-count bound with overpopulation evidence", %{dir: dir} do
      for i <- 1..5 do
        assert :ok =
                 Persistence.save_eval_run_file(
                   "count-#{i}",
                   %{model: "m", timestamp: "2026-01-0#{i}T00:00:00Z"},
                   dir: dir
                 )
      end

      assert {:error, {:max_files_exceeded, evidence}} =
               Persistence.list_eval_run_files(dir: dir, max_files: 3)

      assert is_map(evidence)
      assert evidence.max_files == 3
      assert evidence.seen >= 4 or evidence[:name_count]
      assert evidence.reason in [:too_many_run_files, :directory_overpopulated]
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
      assert :ok =
               Persistence.save_eval_run_file("ceil-1", %{model: "m"}, dir: dir)

      assert {:ok, runs} =
               Persistence.list_eval_run_files(dir: dir, max_files: 10_000_000)

      assert length(runs) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Root identity / least privilege
  # ---------------------------------------------------------------------------

  describe "security regression: root identity and permissions" do
    test "created store root is mode 0700", %{base: base} do
      new_dir = Path.join(base, "priv-store")
      refute File.exists?(new_dir)

      assert :ok =
               Persistence.save_eval_run_file("perm-run", %{model: "m"}, dir: new_dir)

      {:ok, stat} = File.stat(new_dir)
      # Lower 9 permission bits
      assert Bitwise.band(stat.mode, 0o777) == 0o700
    end

    test "published run file is mode 0600", %{dir: dir} do
      assert :ok =
               Persistence.save_eval_run_file("mode-run", %{model: "m"}, dir: dir)

      {:ok, stat} = File.stat(Path.join(dir, "mode-run.json"))
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid UTF-8 / JSON
  # ---------------------------------------------------------------------------

  describe "security regression: invalid content handling" do
    test "rejects invalid UTF-8 on load", %{dir: dir} do
      path = Path.join(dir, "bad-utf8.json")
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

  # ---------------------------------------------------------------------------
  # Config fingerprint integrity
  # ---------------------------------------------------------------------------

  describe "security regression: config fingerprint ordering and collisions" do
    test "fingerprint is stable across map construction order" do
      a = %{timeout: 60, stream: true, model: "x", nested: %{b: 2, a: 1}}
      b = %{nested: %{a: 1, b: 2}, model: "x", stream: true, timeout: 60}
      fa = Persistence.eval_config_fingerprint(a)
      fb = Persistence.eval_config_fingerprint(b)
      assert fa == fb
      assert fa =~ ~r/^sha256:[0-9a-f]{64}$/
    end

    test "atom/string key collisions yield nil fingerprint (reject)" do
      colliding = Map.merge(%{k: 1}, %{"k" => 2})
      assert Persistence.eval_config_fingerprint(colliding) == nil
    end

    test "fingerprint does not use erlang term_to_binary wire format" do
      fp = Persistence.eval_config_fingerprint(%{a: 1, b: "two"})
      assert is_binary(fp)
      # term_to_binary fingerprints from the parent would still hash, but the
      # canonical path must treat string/atom key forms as the same key when
      # values agree — parent term_to_binary treats them as distinct maps.
      same = Persistence.eval_config_fingerprint(%{"a" => 1, "b" => "two"})
      assert fp == same
    end
  end

  # ---------------------------------------------------------------------------
  # Dataset hashing integrity
  # ---------------------------------------------------------------------------

  describe "security regression: dataset hash streaming and symlink reject" do
    test "hashes large file in bounded chunks (streaming, deterministic)", %{base: base} do
      path = Path.join(base, "large.jsonl")
      # ~256 KiB — larger than the 64 KiB chunk size
      content = String.duplicate("abcdefghijklmnopqrstuvwxyz\n", 10_000)
      File.write!(path, content)

      h1 = Persistence.eval_dataset_hash(path)
      h2 = Persistence.eval_dataset_hash(path)
      assert h1 == h2
      assert h1 =~ ~r/^sha256:[0-9a-f]{64}$/

      expected =
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

      assert h1 == expected
    end

    test "refuses to hash through a symlink", %{base: base, outside: outside} do
      real = Path.join(outside, "dataset.jsonl")
      File.write!(real, "secret-data\n")
      link = Path.join(base, "dataset-link.jsonl")
      File.ln_s!(real, link)

      assert Persistence.eval_dataset_hash(link) == nil
    end
  end
end
