defmodule Arbor.Security.Store.JSONFileDurableCasSecurityRegressionTest do
  @moduledoc """
  Causal security regression for JSONFile local-node durable CAS (P2).

  Candidate-only callbacks are reached through `function_exported?/3` + `apply/3`
  so this file fails behaviorally on the parent revision without undefined-function
  compile warnings.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.Store.JSONFile

  test "security regression: JSONFile exports durable CAS with single-winner insert and ABA fence" do
    assert Code.ensure_loaded?(JSONFile)
    assert function_exported?(JSONFile, :compare_and_swap, 4)
    assert function_exported?(JSONFile, :compare_and_delete, 3)
    assert function_exported?(JSONFile, :durability_class, 1)

    dir = unique_dir("jsonfile-cas-sec")
    opts = [base_dir: dir, name: "capabilities"]

    assert apply(JSONFile, :durability_class, [opts]) == :node_restart

    key = "sec_race"

    tasks =
      for i <- 1..6 do
        Task.async(fn ->
          rec = Record.new(key, %{"i" => i})
          apply(JSONFile, :compare_and_swap, [key, :not_found, rec, opts])
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 5

    {:ok, %Record{generation: 1, revision: 1} = winner} =
      Enum.find(results, &match?({:ok, _}, &1))

    assert :ok = apply(JSONFile, :compare_and_delete, [key, winner, opts])

    assert {:ok, %Record{generation: 2, revision: 1}} =
             apply(JSONFile, :compare_and_swap, [
               key,
               :not_found,
               Record.new(key, %{"again" => true}),
               opts
             ])

    # Stale pre-delete token must not win after delete/reinsert (ABA).
    assert {:error, :conflict} =
             apply(JSONFile, :compare_and_swap, [
               key,
               {:value, winner},
               Record.update(winner, %{"stale" => true}),
               opts
             ])
  end

  test "security regression: list cannot traverse outside base through a legacy namespace" do
    root = unique_dir("jsonfile-list-containment-sec")
    base = Path.join(root, "base")
    outside = Path.join(root, "outside")
    File.mkdir_p!(base)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel.json"), ~s({"data":{"secret":true}}))

    assert {:ok, []} = JSONFile.list(base_dir: base, name: "../outside")
  end

  test "security regression: v2 records with empty logical IDs fail closed" do
    dir = unique_dir("jsonfile-empty-id-sec")
    opts = [base_dir: dir, name: "capabilities"]
    key = "empty_id"
    assert :ok = JSONFile.put(key, Record.new(key, %{"accepted" => false}), opts)

    real_base = Path.expand(dir, File.cwd!())
    ns_digest = digest_hex(<<1, "capabilities">>)
    key_digest = digest_hex(<<2, key::binary>>)
    v2_path = Path.join([real_base, "ns_" <> ns_digest, key_digest <> ".json"])

    File.mkdir_p!(Path.dirname(v2_path))

    File.write!(
      v2_path,
      Jason.encode!(%{
        "version" => 2,
        "namespace" => "capabilities",
        "key" => key,
        "entry" => %{
          "kind" => "record",
          "id" => "",
          "key" => key,
          "generation" => 1,
          "revision" => 1,
          "inserted_at" => nil,
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{},
          "metadata" => %{}
        }
      })
    )

    assert {:error, :malformed_envelope} = JSONFile.get(key, opts)
  end

  defp unique_dir(label) do
    rel = Path.join("var", "#{label}-#{:erlang.unique_integer([:positive])}")
    abs = Path.expand(rel, File.cwd!())
    File.mkdir_p!(abs)
    on_exit(fn -> File.rm_rf!(abs) end)
    rel
  end

  defp digest_hex(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
