defmodule Arbor.Security.Store.JSONFileDurableCasTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.Store.JSONFile

  setup do
    dir = unique_dir("jsonfile-cas")
    opts = [base_dir: dir, name: "capabilities"]
    %{dir: dir, opts: opts}
  end

  test "durability_class is node_restart", %{opts: opts} do
    assert JSONFile.durability_class(opts) == :node_restart
  end

  test "put insert and update advance fencing via Revision", %{opts: opts} do
    rec = Record.new("k1", %{"v" => 1}, metadata: %{"m" => true})
    assert :ok = JSONFile.put("k1", rec, opts)

    assert {:ok, %Record{generation: 1, revision: 1, id: id} = stored} =
             JSONFile.get("k1", opts)

    assert is_binary(id)
    assert stored.data == %{"v" => 1}
    assert stored.metadata == %{"m" => true}

    assert :ok = JSONFile.put("k1", Record.update(stored, %{"v" => 2}), opts)

    assert {:ok, %Record{generation: 1, revision: 2, id: ^id, data: %{"v" => 2}}} =
             JSONFile.get("k1", opts)
  end

  test "compare_and_swap not_found insert, update, stale conflict", %{opts: opts} do
    rec = Record.new("cas_k", %{"n" => 1})

    assert {:ok, %Record{generation: 1, revision: 1} = s1} =
             JSONFile.compare_and_swap("cas_k", :not_found, rec, opts)

    assert {:error, :conflict} =
             JSONFile.compare_and_swap("cas_k", :not_found, Record.new("cas_k", %{}), opts)

    updated = Record.update(s1, %{"n" => 2})

    assert {:ok, %Record{generation: 1, revision: 2} = s2} =
             JSONFile.compare_and_swap("cas_k", {:value, s1}, updated, opts)

    assert {:error, :conflict} =
             JSONFile.compare_and_swap("cas_k", {:value, s1}, updated, opts)

    assert {:ok, ^s2} = JSONFile.get("cas_k", opts)
  end

  test "compare_and_delete, tombstone, and delete/reinsert ABA", %{opts: opts} do
    rec = Record.new("aba", %{"x" => 1})

    assert {:ok, %Record{generation: 1, revision: 1} = s1} =
             JSONFile.compare_and_swap("aba", :not_found, rec, opts)

    assert :ok = JSONFile.compare_and_delete("aba", s1, opts)
    assert {:error, :not_found} = JSONFile.get("aba", opts)
    assert JSONFile.exists?("aba", opts) == false

    assert {:error, :conflict} = JSONFile.compare_and_delete("aba", s1, opts)

    assert {:ok, %Record{generation: 2, revision: 1} = s2} =
             JSONFile.compare_and_swap("aba", :not_found, Record.new("aba", %{"x" => 9}), opts)

    assert {:error, :conflict} =
             JSONFile.compare_and_swap("aba", {:value, s1}, Record.update(s1, %{"x" => 0}), opts)

    assert {:ok, ^s2} = JSONFile.get("aba", opts)
  end

  test "delete leaves generation tombstone for reinsert fence", %{opts: opts} do
    assert :ok = JSONFile.put("del", Record.new("del", %{"a" => 1}), opts)
    assert {:ok, %Record{generation: 1}} = JSONFile.get("del", opts)
    assert :ok = JSONFile.delete("del", opts)
    assert {:error, :not_found} = JSONFile.get("del", opts)

    assert {:ok, %Record{generation: 2, revision: 1}} =
             JSONFile.compare_and_swap("del", :not_found, Record.new("del", %{}), opts)
  end

  test "concurrent compare-insert has exactly one winner", %{opts: opts} do
    key = "race_insert"

    tasks =
      for i <- 1..8 do
        Task.async(fn ->
          rec = Record.new(key, %{"i" => i})
          JSONFile.compare_and_swap(key, :not_found, rec, opts)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 7
  end

  test "concurrent compare-update has exactly one winner", %{opts: opts} do
    key = "race_update"

    assert {:ok, base} =
             JSONFile.compare_and_swap(key, :not_found, Record.new(key, %{"n" => 0}), opts)

    tasks =
      for i <- 1..8 do
        Task.async(fn ->
          JSONFile.compare_and_swap(key, {:value, base}, Record.update(base, %{"n" => i}), opts)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 7
  end

  test "concurrent compare-delete has exactly one winner", %{opts: opts} do
    key = "race_delete"
    assert {:ok, base} = JSONFile.compare_and_swap(key, :not_found, Record.new(key, %{}), opts)

    tasks =
      for _ <- 1..8 do
        Task.async(fn -> JSONFile.compare_and_delete(key, base, opts) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 7
  end

  test "digest paths stay under base; traversal keys cannot escape", %{dir: dir, opts: opts} do
    evil = "../escape"

    # invalid for legacy path but valid UTF-8 key after validation? ".." alone may pass UTF-8 bounds
    # Our key validation allows ".." as bytes; digest path must remain under base.
    assert :ok = JSONFile.put(evil, Record.new(evil, %{"ok" => true}), opts)
    assert {:ok, %Record{data: %{"ok" => true}}} = JSONFile.get(evil, opts)

    assert {:ok, real_base} = SafePath.resolve_real(Path.expand(dir, File.cwd!()))

    ns_digest =
      :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)

    key_digest = :crypto.hash(:sha256, <<2, evil::binary>>) |> Base.encode16(case: :lower)
    expected = Path.join([real_base, "ns_" <> ns_digest, key_digest <> ".json"])
    assert File.regular?(expected)
    refute File.exists?(Path.join(real_base, "../escape.json"))
  end

  test "namespaces do not alias", %{dir: dir} do
    a = [base_dir: dir, name: "ns_a"]
    b = [base_dir: dir, name: "ns_b"]
    key = "same_key"

    assert :ok = JSONFile.put(key, Record.new(key, %{"ns" => "a"}), a)
    assert :ok = JSONFile.put(key, Record.new(key, %{"ns" => "b"}), b)

    assert {:ok, %Record{data: %{"ns" => "a"}}} = JSONFile.get(key, a)
    assert {:ok, %Record{data: %{"ns" => "b"}}} = JSONFile.get(key, b)
  end

  test "malformed and mismatched v2 fail closed without legacy fallback", %{dir: dir, opts: opts} do
    key = "poison"
    assert :ok = JSONFile.put(key, Record.new(key, %{"good" => true}), opts)
    assert {:ok, stored} = JSONFile.get(key, opts)

    # Locate v2 path and corrupt it; place legacy that would otherwise succeed.
    real_base = resolve_base!(dir)
    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    key_digest = :crypto.hash(:sha256, <<2, key::binary>>) |> Base.encode16(case: :lower)
    v2 = Path.join([real_base, "ns_" <> ns_digest, key_digest <> ".json"])

    File.write!(v2, Jason.encode!(%{"version" => 2, "namespace" => "capabilities", "key" => key}))

    legacy_dir = Path.join(real_base, "capabilities")
    File.mkdir_p!(legacy_dir)

    File.write!(
      Path.join(legacy_dir, key <> ".json"),
      Jason.encode!(%{"data" => %{"from" => "legacy"}, "metadata" => %{}})
    )

    assert {:error, :malformed_envelope} = JSONFile.get(key, opts)

    # Identity mismatch: wrong key inside envelope (updated_at required non-null)
    File.write!(
      v2,
      Jason.encode!(%{
        "version" => 2,
        "namespace" => "capabilities",
        "key" => "other",
        "entry" => %{
          "kind" => "record",
          "id" => "other",
          "key" => "other",
          "generation" => 1,
          "revision" => 1,
          "inserted_at" => nil,
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{},
          "metadata" => %{}
        }
      })
    )

    assert {:error, reason} = JSONFile.get(key, opts)
    assert reason in [:identity_mismatch, :malformed_envelope]
    refute match?({:ok, %Record{data: %{"from" => "legacy"}}}, JSONFile.get(key, opts))
    assert stored.generation == 1
  end

  test "only exact temp filename pattern is ignored; malformed dot-json fails", %{
    dir: dir,
    opts: opts
  } do
    assert :ok = JSONFile.put("live", Record.new("live", %{}), opts)
    real_base = resolve_base!(dir)
    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    ns_dir = Path.join(real_base, "ns_" <> ns_digest)

    key_digest = :crypto.hash(:sha256, <<2, "live">>) |> Base.encode16(case: :lower)
    # Exact staging pattern ignored
    File.write!(Path.join(ns_dir, ".#{key_digest}.1.abcdef01.tmp"), "{}")
    assert {:ok, keys} = JSONFile.list(opts)
    assert "live" in keys

    # Malformed leading-dot json is authoritative and must fail closed
    File.write!(Path.join(ns_dir, ".evil.json"), "{}")
    assert {:error, reason} = JSONFile.list(opts)
    assert reason in [:malformed_envelope, :identity_mismatch, :invalid_managed_target]
  end

  test "authoritative inventory counts tombstones toward the bound", %{opts: opts} do
    assert :ok = JSONFile.put("a", Record.new("a", %{}), opts)
    assert :ok = JSONFile.put("b", Record.new("b", %{}), opts)
    assert :ok = JSONFile.delete("b", opts)

    assert {:ok, keys} = JSONFile.list(opts)
    assert Enum.sort(keys) == ["a"]

    assert {:error, :inventory_limit_exceeded} =
             JSONFile.list(Keyword.put(opts, :authoritative_limit, 1))

    assert {:ok, ["a"]} = JSONFile.list(Keyword.put(opts, :authoritative_limit, 2))
  end

  test "over-limit inventory performs no legacy migration", %{dir: dir, opts: opts} do
    real_base = resolve_base!(dir)
    legacy_dir = Path.join(real_base, "capabilities")
    File.mkdir_p!(legacy_dir)

    for i <- 1..2 do
      File.write!(
        Path.join(legacy_dir, "leg#{i}.json"),
        Jason.encode!(%{"data" => %{"i" => i}, "metadata" => %{}})
      )
    end

    before =
      for i <- 1..2 do
        path = Path.join(legacy_dir, "leg#{i}.json")
        {path, File.read!(path)}
      end

    assert {:error, :inventory_limit_exceeded} =
             JSONFile.list(Keyword.put(opts, :authoritative_limit, 1))

    for {path, bytes} <- before do
      assert File.read!(path) == bytes
    end

    # No v2 objects created for these keys
    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    ns_dir = Path.join(real_base, "ns_" <> ns_digest)

    if File.dir?(ns_dir) do
      refute Enum.any?(File.ls!(ns_dir), &String.ends_with?(&1, ".json"))
    end
  end

  test "filename digest mismatch fails closed", %{dir: dir, opts: opts} do
    assert :ok = JSONFile.put("realkey", Record.new("realkey", %{"v" => 1}), opts)
    real_base = resolve_base!(dir)
    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    ns_dir = Path.join(real_base, "ns_" <> ns_digest)
    wrong_stem = :crypto.hash(:sha256, <<2, "otherkey">>) |> Base.encode16(case: :lower)
    path = Path.join(ns_dir, wrong_stem <> ".json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 2,
        "namespace" => "capabilities",
        "key" => "realkey",
        "entry" => %{
          "kind" => "record",
          "id" => "realkey",
          "key" => "realkey",
          "generation" => 1,
          "revision" => 1,
          "inserted_at" => nil,
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{"v" => 1},
          "metadata" => %{}
        }
      })
    )

    assert {:error, :identity_mismatch} = JSONFile.list(opts)
  end

  test "symlink managed namespace dir is rejected and cannot read outside root", %{
    dir: dir,
    opts: opts
  } do
    real_base = resolve_base!(dir)
    outside = Path.join(Path.dirname(real_base), "outside-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    File.write!(
      Path.join(outside, "secret.json"),
      Jason.encode!(%{
        "version" => 2,
        "namespace" => "capabilities",
        "key" => "secret",
        "entry" => %{
          "kind" => "record",
          "id" => "secret",
          "key" => "secret",
          "generation" => 1,
          "revision" => 1,
          "inserted_at" => nil,
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{"leak" => true},
          "metadata" => %{}
        }
      })
    )

    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    ns_dir = Path.join(real_base, "ns_" <> ns_digest)
    File.rm_rf!(ns_dir)
    File.ln_s!(outside, ns_dir)

    assert {:error, :symlink_rejected} = JSONFile.list(opts)
    assert {:error, :symlink_rejected} = JSONFile.get("secret", opts)
  end

  test "symlink managed object is rejected", %{dir: dir, opts: opts} do
    assert :ok = JSONFile.put("sym", Record.new("sym", %{"ok" => true}), opts)
    real_base = resolve_base!(dir)
    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    key_digest = :crypto.hash(:sha256, <<2, "sym">>) |> Base.encode16(case: :lower)
    v2 = Path.join([real_base, "ns_" <> ns_digest, key_digest <> ".json"])

    outside =
      Path.join(Path.dirname(real_base), "obj-#{:erlang.unique_integer([:positive])}.json")

    File.write!(outside, File.read!(v2))
    on_exit(fn -> File.rm_rf!(outside) end)
    File.rm!(v2)
    File.ln_s!(outside, v2)

    assert {:error, :symlink_rejected} = JSONFile.get("sym", opts)
  end

  test "legacy namespace symlink is rejected and cannot delete outside root", %{
    dir: dir,
    opts: opts
  } do
    key = "outside_sentinel"
    assert :ok = JSONFile.put(key, Record.new(key, %{"version" => 1}), opts)
    assert {:ok, stored} = JSONFile.get(key, opts)

    real_base = resolve_base!(dir)
    legacy_dir = Path.join(real_base, "capabilities")

    outside =
      Path.join(Path.dirname(real_base), "legacy-outside-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    sentinel = Path.join(outside, key <> ".json")
    File.write!(sentinel, "do-not-delete")
    File.rm_rf!(legacy_dir)
    File.ln_s!(outside, legacy_dir)

    assert {:error, :symlink_rejected} = JSONFile.get("legacy_escape", opts)
    assert {:error, :symlink_rejected} = JSONFile.list(opts)

    assert :ok = JSONFile.put(key, Record.update(stored, %{"version" => 2}), opts)
    assert File.read!(sentinel) == "do-not-delete"
  end

  test "inventory rejects non-object JSON without raising", %{dir: dir, opts: opts} do
    assert :ok = JSONFile.put("live_for_scalar", Record.new("live_for_scalar", %{}), opts)
    real_base = resolve_base!(dir)
    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    key_digest = :crypto.hash(:sha256, <<2, "scalar">>) |> Base.encode16(case: :lower)
    path = Path.join([real_base, "ns_" <> ns_digest, key_digest <> ".json"])
    File.write!(path, "[]")

    assert {:error, :malformed_envelope} = JSONFile.list(opts)
  end

  test "rejects nil data/metadata on input records without silent default", %{opts: opts} do
    bad = %Record{
      id: "bad",
      key: "bad",
      data: nil,
      metadata: %{},
      generation: 0,
      revision: 0,
      inserted_at: nil,
      updated_at: nil
    }

    assert {:error, :malformed_record} = JSONFile.put("bad", bad, opts)

    bad_meta = %{bad | data: %{}, metadata: nil}
    assert {:error, :malformed_record} = JSONFile.put("bad", bad_meta, opts)
  end

  test "rejects structurally invalid DateTimes without raising", %{opts: opts} do
    malformed = %{DateTime.utc_now() | year: nil}

    bad_inserted = Record.new("bad_time", %{}, inserted_at: malformed)
    assert {:error, :malformed_record} = JSONFile.put("bad_time", bad_inserted, opts)

    bad_updated = Record.new("bad_time", %{}, updated_at: malformed)
    assert {:error, :malformed_record} = JSONFile.put("bad_time", bad_updated, opts)
    assert {:error, :not_found} = JSONFile.get("bad_time", opts)
  end

  test "rejects live v2 with null updated_at or gen/rev below 1", %{dir: dir, opts: opts} do
    assert :ok = JSONFile.put("v2bad", Record.new("v2bad", %{}), opts)
    real_base = resolve_base!(dir)
    ns_digest = :crypto.hash(:sha256, <<1, "capabilities">>) |> Base.encode16(case: :lower)
    key_digest = :crypto.hash(:sha256, <<2, "v2bad">>) |> Base.encode16(case: :lower)
    v2 = Path.join([real_base, "ns_" <> ns_digest, key_digest <> ".json"])

    File.write!(
      v2,
      Jason.encode!(%{
        "version" => 2,
        "namespace" => "capabilities",
        "key" => "v2bad",
        "entry" => %{
          "kind" => "record",
          "id" => "v2bad",
          "key" => "v2bad",
          "generation" => 1,
          "revision" => 1,
          "inserted_at" => nil,
          "updated_at" => nil,
          "data" => %{},
          "metadata" => %{}
        }
      })
    )

    assert {:error, :malformed_envelope} = JSONFile.get("v2bad", opts)

    File.write!(
      v2,
      Jason.encode!(%{
        "version" => 2,
        "namespace" => "capabilities",
        "key" => "v2bad",
        "entry" => %{
          "kind" => "record",
          "id" => "v2bad",
          "key" => "v2bad",
          "generation" => 0,
          "revision" => 1,
          "inserted_at" => nil,
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{},
          "metadata" => %{}
        }
      })
    )

    assert {:error, :malformed_envelope} = JSONFile.get("v2bad", opts)
  end

  test "known-unsupported dir fsync still succeeds; unexpected is commit_uncertain", %{
    opts: opts
  } do
    previous = Application.get_env(:arbor_security, :json_file_fsync_dir_fun)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_security, :json_file_fsync_dir_fun)
      else
        Application.put_env(:arbor_security, :json_file_fsync_dir_fun, previous)
      end
    end)

    Application.put_env(:arbor_security, :json_file_fsync_dir_fun, fn _dir ->
      {:error, :eisdir}
    end)

    assert :ok = JSONFile.put("fsync_ok", Record.new("fsync_ok", %{"a" => 1}), opts)
    assert {:ok, %Record{data: %{"a" => 1}}} = JSONFile.get("fsync_ok", opts)
    assert :ok = JSONFile.put("already_deleted", Record.new("already_deleted", %{}), opts)
    assert :ok = JSONFile.delete("already_deleted", opts)

    Application.put_env(:arbor_security, :json_file_fsync_dir_fun, fn _dir ->
      {:error, :eio}
    end)

    # A logical absence represented by a tombstone is already deleted. Repeating
    # ordinary delete must not republish it or manufacture commit uncertainty.
    assert :ok = JSONFile.delete("already_deleted", opts)

    assert {:error, {:publish_commit_uncertain, :eio}} =
             JSONFile.put("fsync_bad", Record.new("fsync_bad", %{"b" => 1}), opts)
  end

  test "legacy migration preserves data/metadata and nil inserted_at fence via Revision", %{
    dir: dir,
    opts: opts
  } do
    real_base = resolve_base!(dir)
    legacy_dir = Path.join(real_base, "capabilities")
    File.mkdir_p!(legacy_dir)

    File.write!(
      Path.join(legacy_dir, "legacy_cap.json"),
      Jason.encode!(%{
        "data" => %{"id" => "legacy_cap", "payload" => "keep"},
        "metadata" => %{"source" => "legacy"}
      })
    )

    assert {:ok, %Record{} = rec} = JSONFile.get("legacy_cap", opts)
    assert rec.id == "legacy_cap"
    assert rec.key == "legacy_cap"
    assert rec.data == %{"id" => "legacy_cap", "payload" => "keep"}
    assert rec.metadata == %{"source" => "legacy"}
    assert rec.generation == 1
    assert rec.revision == 1
    assert is_nil(rec.inserted_at)
    assert %DateTime{} = rec.updated_at

    # Legacy retired after v2 publish
    refute File.exists?(Path.join(legacy_dir, "legacy_cap.json"))

    # Stateless reread
    assert {:ok,
            %Record{generation: 1, revision: 1, inserted_at: nil, data: %{"payload" => "keep"}}} =
             JSONFile.get("legacy_cap", opts)
  end

  test "stateless reread preserves live records and tombstone generation", %{opts: opts} do
    assert {:ok, s1} =
             JSONFile.compare_and_swap(
               "persist",
               :not_found,
               Record.new("persist", %{"v" => 1}),
               opts
             )

    assert :ok = JSONFile.compare_and_delete("persist", s1, opts)

    assert {:ok, %Record{generation: 2, revision: 1}} =
             JSONFile.compare_and_swap(
               "persist",
               :not_found,
               Record.new("persist", %{"v" => 2}),
               opts
             )

    # New call stack, same opts/directory
    assert {:ok, %Record{generation: 2, data: %{"v" => 2}}} = JSONFile.get("persist", opts)
  end

  test "identity-bound max key and namespace accepted", %{dir: dir} do
    key = String.duplicate("k", 512)
    ns = String.duplicate("n", 128)
    opts = [base_dir: dir, name: ns]
    assert :ok = JSONFile.put(key, Record.new(key, %{"ok" => true}), opts)
    assert {:ok, %Record{data: %{"ok" => true}}} = JSONFile.get(key, opts)
  end

  test "exists? is false on errors", %{opts: opts} do
    assert JSONFile.exists?("missing", opts) == false
    # invalid key
    assert JSONFile.exists?("", opts) == false
  end

  test "list returns logical keys after put", %{opts: opts} do
    assert :ok = JSONFile.put("cap_a", Record.new("cap_a", %{"x" => 1}), opts)
    assert :ok = JSONFile.put("cap_b", Record.new("cap_b", %{"x" => 2}), opts)
    assert {:ok, keys} = JSONFile.list(opts)
    assert Enum.sort(keys) == ["cap_a", "cap_b"]
  end

  defp unique_dir(label) do
    rel = Path.join("var", "#{label}-#{:erlang.unique_integer([:positive])}")
    abs = Path.expand(rel, File.cwd!())
    File.mkdir_p!(abs)
    on_exit(fn -> File.rm_rf!(abs) end)
    rel
  end

  defp resolve_base!(dir) do
    expanded = Path.expand(dir, File.cwd!())
    {:ok, real} = SafePath.resolve_real(expanded)
    real
  end
end
