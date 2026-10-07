defmodule Arbor.Security.RevocationLedgerCapacitySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag security: :regression
  @moduletag spec: "SSEC-010"

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuthorityStore

  @store :revocation_ledger_capacity_security_regression_store
  @record_auth_key :crypto.hash(:sha256, "revocation-ledger-capacity-security-regression")

  @tag spec: "SSEC-010"
  test "security regression: more than 256 distinct revocations remain durable" do
    ctx = store_context()
    start_supervised!({AuthorityStore, ctx.opts})

    keys = Enum.map(1..257, &"cap_revocation_capacity_#{&1}")

    Enum.each(keys, fn key ->
      assert {:ok, %Record{generation: 1} = stored} =
               AuthorityStore.acknowledged_compare_and_create(
                 key,
                 :absent,
                 Record.new(key, %{"scope" => key}),
                 name: @store
               )

      assert :ok =
               AuthorityStore.acknowledged_compare_and_delete(key, stored, name: @store)
    end)

    stop_supervised!(@store)
    start_supervised!({AuthorityStore, ctx.opts})

    assert {:ok, %{status: :ready}} = AuthorityStore.hydration_status(name: @store)

    Enum.each([List.first(keys), List.last(keys)], fn key ->
      assert {:ok, {:tombstone, 1}} =
               AuthorityStore.authoritative_entry(key, name: @store)
    end)
  end

  defp store_context do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    fixture_root = Path.join(system_tmp, "revocation-ledger-capacity-#{token}")
    authority_root = Path.join(fixture_root, "authority")
    ledger_root = Path.join(fixture_root, "revocation-fence")
    ledger_path = Path.join(ledger_root, "capability-revocations.json")

    File.mkdir_p!(authority_root)
    File.chmod!(fixture_root, 0o700)
    File.chmod!(authority_root, 0o700)
    File.mkdir_p!(ledger_root)
    File.chmod!(ledger_root, 0o700)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    opts = [
      name: @store,
      namespace: "capabilities",
      backend_opts: [
        base_dir: authority_root,
        record_auth_key: @record_auth_key,
        revocation_ledger_path: ledger_path
      ]
    ]

    %{opts: opts}
  end
end
