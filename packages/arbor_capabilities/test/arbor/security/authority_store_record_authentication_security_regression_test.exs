defmodule Arbor.Security.AuthorityStoreRecordAuthenticationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-001,SSEC-010,SSEC-011"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuthorityStore

  @bad_mac_store :authority_record_bad_mac_security_regression_store
  @legacy_store :authority_record_legacy_security_regression_store
  @revocation_store :authority_record_revocation_security_regression_store
  @quarantine_store :authority_record_quarantine_security_regression_store
  @legacy_inventory_store :authority_record_legacy_inventory_security_regression_store
  @record_auth_key :crypto.hash(:sha256, "authority-store-security-regression-key")

  @tag spec: "SSEC-001,SSEC-010,SSEC-011"
  test "security regression: a modified authenticated authority record is rejected on restore" do
    ctx = start_store(@bad_mac_store, "capabilities")
    key = "cap_bad_mac"

    assert {:ok, %Record{}} =
             AuthorityStore.acknowledged_put(key, Record.new(key, %{"allow" => false}),
               name: ctx.name
             )

    stop_supervised!(ctx.name)
    path = record_path(ctx.root, ctx.namespace, key)
    envelope = path |> File.read!() |> Jason.decode!()
    tampered = put_in(envelope, ["entry", "data", "allow"], true)
    File.write!(path, Jason.encode!(tampered))

    start_supervised!({AuthorityStore, ctx.opts})

    assert {:ok, %{status: :failed, reason: :record_authentication_failed}} =
             AuthorityStore.hydration_status(name: ctx.name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_get(key, name: ctx.name)
  end

  test "security regression: unauthenticated v2 authority records require offline migration" do
    ctx = store_context(@legacy_store, "capabilities")
    key = "cap_v2"
    path = record_path(ctx.root, ctx.namespace, key)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 2,
        "namespace" => ctx.namespace,
        "key" => key,
        "entry" => %{
          "kind" => "record",
          "id" => key,
          "key" => key,
          "generation" => 1,
          "revision" => 1,
          "inserted_at" => nil,
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{"forged" => true},
          "metadata" => %{}
        }
      })
    )

    File.chmod!(path, 0o600)
    start_supervised!({AuthorityStore, ctx.opts})

    assert {:ok, %{status: :failed, reason: :offline_migration_required}} =
             AuthorityStore.hydration_status(name: ctx.name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_get(key, name: ctx.name)
  end

  test "security regression: restoring pre-revocation bytes cannot resurrect a capability" do
    ctx = start_store(@revocation_store, "capabilities")
    key = "cap_replayed_after_revoke"

    assert {:ok, %Record{generation: 1} = original} =
             AuthorityStore.acknowledged_compare_and_create(
               key,
               :absent,
               Record.new(key, %{"scope" => "original"}),
               name: ctx.name
             )

    path = record_path(ctx.root, ctx.namespace, key)
    pre_revocation_bytes = File.read!(path)

    assert :ok =
             AuthorityStore.acknowledged_compare_and_delete(key, original, name: ctx.name)

    stop_supervised!(ctx.name)
    File.write!(path, pre_revocation_bytes)
    start_supervised!({AuthorityStore, ctx.opts})

    assert {:ok, %{status: :ready}} = AuthorityStore.hydration_status(name: ctx.name)
    assert {:error, :not_found} = AuthorityStore.authoritative_get(key, name: ctx.name)
    assert {:ok, {:tombstone, 1}} = AuthorityStore.authoritative_entry(key, name: ctx.name)

    assert {:ok, %Record{generation: 2, data: %{"scope" => "replacement"}}} =
             AuthorityStore.acknowledged_compare_and_create(
               key,
               {:tombstone, 1},
               Record.new(key, %{"scope" => "replacement"}),
               name: ctx.name
             )
  end

  test "security regression: foreign json is quarantined without poisoning authority hydration" do
    ctx = start_store(@quarantine_store, "capabilities")
    key = "cap_survives_junk"

    assert {:ok, %Record{}} =
             AuthorityStore.acknowledged_put(key, Record.new(key, %{"valid" => true}),
               name: ctx.name
             )

    stop_supervised!(ctx.name)
    namespace_dir = namespace_dir(ctx.root, ctx.namespace)
    junk_path = Path.join(namespace_dir, "unrelated-backup.json")
    File.write!(junk_path, "not-json")
    start_supervised!({AuthorityStore, ctx.opts})

    assert {:ok, %{status: :ready}} = AuthorityStore.hydration_status(name: ctx.name)

    assert {:ok, %Record{data: %{"valid" => true}}} =
             AuthorityStore.authoritative_get(key, name: ctx.name)

    refute File.exists?(junk_path)
    assert [_quarantined] = File.ls!(Path.join(namespace_dir, ".quarantine"))
  end

  @tag spec: "SSEC-011"
  @tag security: :regression
  test "security regression: legacy inventory overflow is rejected before record decoding" do
    ctx = store_context(@legacy_inventory_store, "capabilities")
    legacy_dir = Path.join(ctx.root, ctx.namespace)
    File.mkdir_p!(legacy_dir)

    File.write!(Path.join(legacy_dir, "malformed_a.json"), "not json")
    File.write!(Path.join(legacy_dir, "malformed_b.json"), "not json")

    opts = Keyword.put(ctx.opts, :hydration_limit, 1)
    start_supervised!({AuthorityStore, opts})

    assert {:ok, %{status: :failed, reason: :hydration_limit_exceeded}} =
             AuthorityStore.hydration_status(name: ctx.name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_list(name: ctx.name)
  end

  defp start_store(name, namespace) do
    ctx = store_context(name, namespace)
    start_supervised!({AuthorityStore, ctx.opts})
    ctx
  end

  defp store_context(name, namespace) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    fixture_root = Path.join(system_tmp, "authority-record-auth-#{token}")
    File.mkdir!(fixture_root)
    File.chmod!(fixture_root, 0o700)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    root = Path.join(fixture_root, "authority")
    ledger_root = Path.join(fixture_root, "revocation-fence")
    ledger_path = Path.join(ledger_root, "capability-revocations.json")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    File.mkdir_p!(ledger_root)
    File.chmod!(ledger_root, 0o700)

    opts = [
      name: name,
      namespace: namespace,
      backend_opts: [
        base_dir: root,
        record_auth_key: @record_auth_key,
        revocation_ledger_path: ledger_path
      ]
    ]

    %{name: name, namespace: namespace, opts: opts, root: root}
  end

  defp namespace_dir(root, namespace) do
    digest = :crypto.hash(:sha256, <<1, namespace::binary>>) |> Base.encode16(case: :lower)
    Path.join(root, "ns_" <> digest)
  end

  defp record_path(root, namespace, key) do
    digest = :crypto.hash(:sha256, <<2, key::binary>>) |> Base.encode16(case: :lower)
    Path.join(namespace_dir(root, namespace), digest <> ".json")
  end
end
