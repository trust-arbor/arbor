defmodule Arbor.Persistence.EvalFileStoreSecurityRegressionTest do
  @moduledoc """
  Security regression tests for eval file-store hardening.

  Exercised exclusively through the public `Arbor.Persistence` facade.

  Parent lineage (most recent first):
  - **f9ac0086** — immediate parent for *this* correction pass (dual-pass
    stable-content reads; cryptorandom exclusive temp/euid probe; bounded
    config_fingerprint; honest enumeration worker; post-rename verify
    side-effect honesty). New dual-pass / fingerprint-bound claims must fail
    on f9ac0086 (second-resolution metadata race) and pass here.
  - **d7df3521** — identity match completeness, preflight encode bounds,
    exact one-suffix binding, trusted-private-root before chmod, bounded
    enumeration worker, publish identity verify. Dual-pass mutation tests
    still fail-closed on candidate while d7 returns a hash/decode path.
  - 649fe909 / 07de3232 — earlier ownership extraction + first hardening.
    Characterization of older parents is separate; do not claim every test
    fails 07de/649.

  Each assertion group is independent so an earlier failure does not mask
  a later security claim. Identity failures must surface as `:file_changed`
  (or nil for dataset hash), not as decode/schema errors.
  """
  use ExUnit.Case, async: true
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Persistence

  @exclusive_mkdir_retries 16

  setup do
    base = exclusive_owned_temp_base!("eval_sec_")
    # Cleanup only the exclusively owned base — never foreign residue.
    on_exit(fn -> File.rm_rf(base) end)

    dir = Path.join(base, "store")
    outside = Path.join(base, "outside")
    File.mkdir_p!(dir)
    File.mkdir_p!(outside)
    # Trusted-private-root contract: existing roots must be owner-only.
    File.chmod!(dir, 0o700)
    File.chmod!(outside, 0o700)
    %{dir: dir, outside: outside, base: base}
  end

  # Cryptorandom atomic File.mkdir-owned base with bounded collision retry.
  # Registers ownership only after exclusive create succeeds.
  defp exclusive_owned_temp_base!(prefix) when is_binary(prefix) do
    tmp = System.tmp_dir!()

    Enum.reduce_while(1..@exclusive_mkdir_retries, :error, fn _, _ ->
      name = prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      path = Path.join(tmp, name)

      case File.mkdir(path) do
        :ok ->
          {:halt, path}

        {:error, :eexist} ->
          {:cont, :error}

        {:error, _} ->
          {:cont, :error}
      end
    end)
    |> case do
      path when is_binary(path) -> path
      :error -> flunk("could not allocate exclusive temp base after retries")
    end
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
      File.chmod!(real, 0o700)
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
  # d7df3521 exact: preflight encode guards (shaped errors before Jason)
  # ---------------------------------------------------------------------------

  describe "security regression d7: bignum and oversized preflight before Jason" do
    test "rejects oversize integer bit ceiling with shaped preflight error", %{dir: dir} do
      # Far beyond the hard bit ceiling; d7 estimated a fixed 24 bytes and
      # would hand the bignum to Jason (or OOM/spin). Candidate must reject
      # with a distinct preflight tag before Jason.
      huge = Bitwise.bsl(1, 70_000)

      assert {:error, {:encode_preflight, :max_integer_bits_exceeded}} =
               Persistence.save_eval_run_file(
                 "bignum-run",
                 %{model: "m", n: huge},
                 dir: dir,
                 max_file_bytes: 50_000
               )

      refute File.exists?(Path.join(dir, "bignum-run.json"))
    end

    test "rejects oversized invalid UTF-8 by byte_size before UTF-8 scan", %{dir: dir} do
      # Invalid UTF-8 payload larger than max_string / max_file budget.
      # Size gate must fire (not a full UTF-8 scan yielding only :invalid_utf8).
      oversized = :binary.copy(<<0xFF>>, 5_000)

      assert {:error, reason} =
               Persistence.save_eval_run_file(
                 "bad-utf8-big",
                 %{model: "m", blob: oversized},
                 dir: dir,
                 max_file_bytes: 500
               )

      assert reason in [:max_file_bytes_exceeded, :max_string_bytes_exceeded]
      refute File.exists?(Path.join(dir, "bad-utf8-big.json"))
    end

    test "rejects oversized object key by byte_size with shaped preflight error", %{dir: dir} do
      big_key = String.duplicate("k", 2_000)

      assert {:error, reason} =
               Persistence.save_eval_run_file(
                 "big-key-run",
                 %{model: "m", data: %{big_key => "v"}},
                 dir: dir,
                 max_file_bytes: 200
               )

      assert reason in [
               :max_file_bytes_exceeded,
               :max_string_bytes_exceeded,
               {:encode_preflight, :max_key_bytes_exceeded}
             ]

      refute File.exists?(Path.join(dir, "big-key-run.json"))
    end
  end

  # ---------------------------------------------------------------------------
  # Load / list id binding
  # ---------------------------------------------------------------------------

  describe "security regression: bind decoded id to filename run_id" do
    test "load rejects file whose JSON id does not match filename", %{dir: dir} do
      path = Path.join(dir, "filename-run.json")
      File.write!(path, ~s({"id":"other-run","model":"m","timestamp":"2026-01-01T00:00:00Z"}))
      File.chmod!(path, 0o600)

      assert {:error, :run_id_mismatch} =
               Persistence.load_eval_run_file("filename-run", dir: dir)
    end

    test "load rejects file missing id field", %{dir: dir} do
      path = Path.join(dir, "no-id-run.json")
      File.write!(path, ~s({"model":"m","timestamp":"2026-01-01T00:00:00Z"}))
      File.chmod!(path, 0o600)

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
  # d7df3521 exact: one terminal ".json" suffix binding
  # ---------------------------------------------------------------------------

  describe "security regression d7: exact one-suffix filename binding" do
    test "saved id legit.json lists and loads as legit.json not legit", %{dir: dir} do
      assert :ok =
               Persistence.save_eval_run_file(
                 "legit.json",
                 %{model: "m", timestamp: "2026-03-01T00:00:00Z"},
                 dir: dir
               )

      assert File.exists?(Path.join(dir, "legit.json.json"))

      assert {:ok, loaded} = Persistence.load_eval_run_file("legit.json", dir: dir)
      assert loaded["id"] == "legit.json"

      assert {:ok, runs} = Persistence.list_eval_run_files(dir: dir)
      ids = Enum.map(runs, & &1["id"])
      assert "legit.json" in ids
      refute "legit" in ids
    end

    test "crafted a.json.json on disk does not bind as run id a", %{dir: dir} do
      # Double-suffix filename must reconstruct to "a.json", not strip to "a".
      path = Path.join(dir, "a.json.json")
      File.write!(path, ~s({"id":"a.json","model":"m","timestamp":"2026-03-02T00:00:00Z"}))
      File.chmod!(path, 0o600)

      assert {:ok, loaded} = Persistence.load_eval_run_file("a.json", dir: dir)
      assert loaded["id"] == "a.json"

      assert {:ok, runs} = Persistence.list_eval_run_files(dir: dir)
      ids = Enum.map(runs, & &1["id"])
      assert "a.json" in ids
      refute "a" in ids
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
      assert evidence.seen >= 4 or evidence[:name_count] or evidence[:reason]

      assert evidence.reason in [
               :too_many_run_files,
               :directory_overpopulated,
               :enumeration_worker_killed,
               :enumeration_timeout
             ]
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
  # d7df3521 exact: bounded enumeration via owner-facing behavior
  # ---------------------------------------------------------------------------

  describe "security regression d7: bounded enumeration owner behavior" do
    test "enumeration returns only bounded candidates under private root", %{dir: dir} do
      for i <- 1..3 do
        assert :ok =
                 Persistence.save_eval_run_file(
                   "enum-#{i}",
                   %{model: "m", timestamp: "2026-02-0#{i}T00:00:00Z"},
                   dir: dir
                 )
      end

      # Noise entries must not become run candidates or explode the owner list.
      File.write!(Path.join(dir, "not-json.txt"), "x")
      File.write!(Path.join(dir, ".hidden.json"), ~s({"id":"hidden"}))
      File.mkdir!(Path.join(dir, "subdir.json"))

      assert {:ok, runs} = Persistence.list_eval_run_files(dir: dir)
      ids = Enum.map(runs, & &1["id"])
      assert Enum.sort(ids) == ["enum-1", "enum-2", "enum-3"]
    end

    test "overpopulated directory fails with evidence map not silent truncate", %{dir: dir} do
      # Create more run files than max_files; owner must see structured error.
      for i <- 1..6 do
        assert :ok =
                 Persistence.save_eval_run_file(
                   "pop-#{i}",
                   %{model: "m", timestamp: "2026-04-0#{i}T00:00:00Z"},
                   dir: dir
                 )
      end

      assert {:error, {:max_files_exceeded, evidence}} =
               Persistence.list_eval_run_files(dir: dir, max_files: 2)

      assert is_map(evidence)
      assert evidence.max_files == 2
      assert is_atom(evidence.reason)
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
  # d7df3521 exact: insecure root rejection + symlink target mode unchanged
  # ---------------------------------------------------------------------------

  describe "security regression d7: trusted private root before chmod" do
    test "rejects existing 0777 root without silently chmodding it", %{base: base} do
      insecure = Path.join(base, "insecure-store")
      File.mkdir_p!(insecure)
      File.chmod!(insecure, 0o777)
      {:ok, before} = File.stat(insecure)
      assert Bitwise.band(before.mode, 0o777) == 0o777

      assert {:error, :insecure_root_permissions} =
               Persistence.save_eval_run_file("x", %{model: "m"}, dir: insecure)

      {:ok, after_stat} = File.stat(insecure)
      # Must not have been silently chmod'd to 0700.
      assert Bitwise.band(after_stat.mode, 0o777) == 0o777
      refute File.exists?(Path.join(insecure, "x.json"))
    end

    test "rejects existing 0755 root (group/world bits)", %{base: base} do
      open_dir = Path.join(base, "open-store")
      File.mkdir_p!(open_dir)
      File.chmod!(open_dir, 0o755)

      assert {:error, :insecure_root_permissions} =
               Persistence.list_eval_run_files(dir: open_dir)
    end

    test "symlink root does not chmod the real target directory", %{base: base, outside: outside} do
      real = Path.join(outside, "real-0755")
      File.mkdir_p!(real)
      File.chmod!(real, 0o755)
      {:ok, before} = File.stat(real)
      assert Bitwise.band(before.mode, 0o777) == 0o755

      link_root = Path.join(base, "symlink-root-chmod")
      File.ln_s!(real, link_root)

      # d7 chmod'd the symlink target to 0700 before rejecting. Candidate must
      # reject without mutating the target's mode.
      assert {:error, :symlink_root} =
               Persistence.save_eval_run_file("r1", %{model: "m"}, dir: link_root)

      {:ok, after_stat} = File.stat(real)
      assert Bitwise.band(after_stat.mode, 0o777) == 0o755
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid UTF-8 / JSON
  # ---------------------------------------------------------------------------

  describe "security regression: invalid content handling" do
    test "rejects invalid UTF-8 on load", %{dir: dir} do
      path = Path.join(dir, "bad-utf8.json")
      File.write!(path, <<0xFF, 0xFE, "{}">>)
      File.chmod!(path, 0o600)

      assert {:error, :invalid_utf8} = Persistence.load_eval_run_file("bad-utf8", dir: dir)
    end

    test "rejects invalid JSON on load", %{dir: dir} do
      path = Path.join(dir, "bad-json.json")
      File.write!(path, "not-json{")
      File.chmod!(path, 0o600)

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
      same = Persistence.eval_config_fingerprint(%{"a" => 1, "b" => "two"})
      assert fp == same
    end
  end

  # ---------------------------------------------------------------------------
  # f9ac0086 exact: config_fingerprint system ceilings (public facade)
  # ---------------------------------------------------------------------------

  describe "security regression f9: config_fingerprint bounded canonicalization" do
    test "rejects excessive nesting depth without materializing a digest" do
      deep =
        Enum.reduce(1..40, "leaf", fn _, acc ->
          %{"n" => acc}
        end)

      # f9ac0086 recursed without a depth ceiling and would still fingerprint.
      assert Persistence.eval_config_fingerprint(deep) == nil
    end

    test "rejects oversized string values without a fingerprint" do
      huge = String.duplicate("x", 1_100_000)
      assert Persistence.eval_config_fingerprint(%{blob: huge}) == nil
    end

    test "still fingerprints modest nested configs deterministically" do
      cfg = %{a: 1, b: %{c: [true, false, nil], d: "ok"}}
      fp = Persistence.eval_config_fingerprint(cfg)
      assert fp =~ ~r/^sha256:[0-9a-f]{64}$/
      assert Persistence.eval_config_fingerprint(cfg) == fp
    end
  end

  # ---------------------------------------------------------------------------
  # Dataset hashing integrity
  # ---------------------------------------------------------------------------

  describe "security regression: dataset hash streaming and symlink reject" do
    test "hashes large file in bounded chunks (streaming, deterministic)", %{base: base} do
      path = Path.join(base, "large.jsonl")
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

  # ---------------------------------------------------------------------------
  # Same-inode mutation fail-closed (hash + load) — dual-pass stable content
  # Deterministic: mutator-ready handshake, large same-size fixture, always
  # stop/await mutators even when assertions fail.
  # d7 parent: returns a hash / decode path; candidate fails closed.
  # f9ac0086: flaky under second-resolution metadata alone.
  # ---------------------------------------------------------------------------

  describe "security regression d7: same-inode mutation fail closed" do
    test "dataset hash returns nil when same-inode content mutates during dual pass", %{
      base: base
    } do
      path = Path.join(base, "mutate-dataset.jsonl")
      # Large enough that dual full passes overlap continuous mutation.
      size = 768_000
      content_a = :binary.copy("A", size)
      content_b = :binary.copy("B", size)
      File.write!(path, content_a)

      stop = :atomics.new(1, signed: false)
      :atomics.put(stop, 1, 0)
      parent = self()
      ready_ref = make_ref()

      mutator =
        spawn(fn ->
          send(parent, {ready_ref, :ready})

          receive do
            {^ready_ref, :go} -> :ok
          after
            5_000 -> :ok
          end

          # Prove first mutation completed before the reader starts.
          _ = File.write(path, content_b)
          send(parent, {ready_ref, :mutated})

          loop = fn loop ->
            if :atomics.get(stop, 1) == 1 do
              :ok
            else
              _ = File.write(path, content_a)
              _ = File.write(path, content_b)
              loop.(loop)
            end
          end

          loop.(loop)
        end)

      try do
        receive do
          {^ready_ref, :ready} -> :ok
        after
          5_000 -> flunk("mutator never became ready")
        end

        send(mutator, {ready_ref, :go})

        receive do
          {^ready_ref, :mutated} -> :ok
        after
          5_000 -> flunk("mutator never performed first write")
        end

        result = Persistence.eval_dataset_hash(path)
        assert result == nil
      after
        :atomics.put(stop, 1, 1)

        ref = Process.monitor(mutator)
        Process.exit(mutator, :kill)

        receive do
          {:DOWN, ^ref, :process, ^mutator, _} -> :ok
        after
          5_000 -> :ok
        end
      end
    end

    test "JSON load returns file_changed not decode error on same-inode mutation", %{dir: dir} do
      path = Path.join(dir, "mutate-load.json")
      # Same size A/B so second-resolution mtime alone cannot detect the race;
      # dual-pass digest equality must fail closed. Valid JSON vs non-JSON so a
      # weak single-pass identity check surfaces as decode_error (d7 path).
      pad = 400_000

      json_a =
        ~s({"id":"mutate-load","model":"m","blob":") <> String.duplicate("x", pad) <> ~s("})

      junk_b = :binary.copy("Z", byte_size(json_a))
      File.write!(path, json_a)
      File.chmod!(path, 0o600)

      stop = :atomics.new(1, signed: false)
      :atomics.put(stop, 1, 0)
      parent = self()
      ready_ref = make_ref()

      mutator =
        spawn(fn ->
          send(parent, {ready_ref, :ready})

          receive do
            {^ready_ref, :go} -> :ok
          after
            5_000 -> :ok
          end

          _ = File.write(path, junk_b)
          _ = File.chmod(path, 0o600)
          send(parent, {ready_ref, :mutated})

          loop = fn loop ->
            if :atomics.get(stop, 1) == 1 do
              :ok
            else
              _ = File.write(path, json_a)
              _ = File.chmod(path, 0o600)
              _ = File.write(path, junk_b)
              _ = File.chmod(path, 0o600)
              loop.(loop)
            end
          end

          loop.(loop)
        end)

      try do
        receive do
          {^ready_ref, :ready} -> :ok
        after
          5_000 -> flunk("mutator never became ready")
        end

        send(mutator, {ready_ref, :go})

        receive do
          {^ready_ref, :mutated} -> :ok
        after
          5_000 -> flunk("mutator never performed first write")
        end

        result = Persistence.load_eval_run_file("mutate-load", dir: dir)
        # Must be the identity/stable-content failure, not a masked decode error.
        assert result == {:error, :file_changed}
      after
        :atomics.put(stop, 1, 1)

        ref = Process.monitor(mutator)
        Process.exit(mutator, :kill)

        receive do
          {:DOWN, ^ref, :process, ^mutator, _} -> :ok
        after
          5_000 -> :ok
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # f9ac0086 exact: stable dual-pass content under trusted root (static)
  # ---------------------------------------------------------------------------

  describe "security regression f9: dual-pass stable content (static happy path)" do
    test "stable dataset hashes equal dual-pass digest of content", %{base: base} do
      path = Path.join(base, "stable-dual.jsonl")
      content = String.duplicate("stable-line\n", 50_000)
      File.write!(path, content)

      hash = Persistence.eval_dataset_hash(path)
      expected = "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      assert hash == expected
    end

    test "stable load returns bound run after dual-pass", %{dir: dir} do
      assert :ok =
               Persistence.save_eval_run_file(
                 "stable-load",
                 %{model: "m", blob: String.duplicate("q", 20_000)},
                 dir: dir
               )

      assert {:ok, loaded} = Persistence.load_eval_run_file("stable-load", dir: dir)
      assert loaded["id"] == "stable-load"
      assert loaded["model"] == "m"
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup on pre-publish failure
  # ---------------------------------------------------------------------------

  describe "security regression d7: temp cleanup on publish failure" do
    test "cleans exclusive temp when target path is a non-file directory", %{dir: dir} do
      # rename onto an existing directory entry fails; temp must not linger.
      File.mkdir!(Path.join(dir, "blocked.json"))

      assert {:error, _} =
               Persistence.save_eval_run_file("blocked", %{model: "m"}, dir: dir)

      leftovers =
        File.ls!(dir)
        |> Enum.filter(&String.starts_with?(&1, ".eval-tmp-"))

      assert leftovers == []
    end
  end
end
