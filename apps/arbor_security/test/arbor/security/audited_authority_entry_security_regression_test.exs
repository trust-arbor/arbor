defmodule Arbor.Security.AuditedAuthorityEntrySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuthorityStore

  @moduletag :fast

  setup do
    root = Path.join(System.tmp_dir!(), "audit_entry_#{System.unique_integer([:positive])}")
    name = :audited_authority_entry_test
    opts = [name: name, namespace: "audit-entry", backend_opts: [base_dir: root]]
    start_supervised!({AuthorityStore, opts})
    on_exit(fn -> File.rm_rf!(root) end)
    %{name: name, opts: opts}
  end

  test "security regression: exact absent create cannot cross a deleted incarnation", %{
    name: name
  } do
    assert {:ok, :absent} = entry(name, "one")
    original = Record.new("one", %{"value" => 1}, id: "fixed-first-record")
    assert {:ok, first} = create(name, "one", :absent, original)
    assert first.id == original.id
    assert {first.generation, first.revision} == {1, 1}
    assert :ok = AuthorityStore.acknowledged_compare_and_delete("one", first, name: name)
    assert {:ok, {:tombstone, 1}} = entry(name, "one")

    replacement = Record.new("one", %{"value" => 2}, id: "fixed-second-record")
    assert {:error, :conflict} = create(name, "one", :absent, replacement)
    assert {:ok, second} = create(name, "one", {:tombstone, 1}, replacement)
    assert second.id == replacement.id
    assert {second.generation, second.revision} == {2, 1}
    assert {:error, :conflict} = create(name, "one", {:tombstone, 1}, original)
    assert {:ok, ^second} = AuthorityStore.authoritative_get("one", name: name)
  end

  test "security regression: cold tombstone remains observable and stale create refuses", ctx do
    assert {:ok, record} = create(ctx.name, "cold", :absent, Record.new("cold", %{}))
    assert :ok = AuthorityStore.acknowledged_compare_and_delete("cold", record, name: ctx.name)
    stop_supervised!(ctx.name)
    start_supervised!({AuthorityStore, ctx.opts})
    assert {:ok, {:tombstone, 1}} = entry(ctx.name, "cold")
    assert {:error, :conflict} = create(ctx.name, "cold", :absent, Record.new("cold", %{}))
  end

  test "security regression: wrong-key and malformed entry fences never create", %{name: name} do
    assert {:error, :key_mismatch} = create(name, "target", :absent, Record.new("other", %{}))

    assert {:error, :invalid_expected} =
             create(name, "target", {:tombstone, 0}, Record.new("target", %{}))

    assert {:ok, :absent} = entry(name, "target")
  end

  defp entry(name, key), do: apply(AuthorityStore, :authoritative_entry, [key, [name: name]])

  defp create(name, key, expected, replacement),
    do:
      apply(AuthorityStore, :acknowledged_compare_and_create, [
        key,
        expected,
        replacement,
        [name: name]
      ])
end
