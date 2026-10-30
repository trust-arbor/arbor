defmodule Arbor.Security.Store.RevocationLedgerSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-010"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuthorityStore

  @loss_store :revocation_ledger_loss_security_regression_store
  @upgrade_store :revocation_ledger_upgrade_security_regression_store
  @marker_store :revocation_ledger_marker_security_regression_store
  @shared_store_names [
    :revocation_shared_ledger_store_1,
    :revocation_shared_ledger_store_2,
    :revocation_shared_ledger_store_3,
    :revocation_shared_ledger_store_4,
    :revocation_shared_ledger_store_5,
    :revocation_shared_ledger_store_6,
    :revocation_shared_ledger_store_7,
    :revocation_shared_ledger_store_8
  ]
  @record_auth_key :crypto.hash(:sha256, "revocation-ledger-security-regression")
  @contention_payload String.duplicate("x", 60_000)

  setup do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    fixture_root = Path.join(system_tmp, "revocation-ledger-regression-#{token}")
    ledger_root = Path.join(fixture_root, "revocation-fence")
    ledger_path = Path.join(ledger_root, "capability-revocations.json")

    File.mkdir_p!(ledger_root)
    File.chmod!(fixture_root, 0o700)
    File.chmod!(ledger_root, 0o700)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    %{fixture_root: fixture_root, ledger_path: ledger_path}
  end

  @tag spec: "SSEC-010"
  test "security regression: losing only the initialized ledger cannot rebase revocation state",
       ctx do
    authority_root = authority_root(ctx.fixture_root, "loss")
    store_opts = authority_store_opts(@loss_store, authority_root, ctx.ledger_path)
    victim = "cap_revoked_before_ledger_loss"

    start_supervised!({AuthorityStore, store_opts})

    assert {:ok, %Record{generation: 1} = original} =
             AuthorityStore.acknowledged_compare_and_create(
               victim,
               :absent,
               Record.new(victim, %{"scope" => "original"}),
               name: @loss_store
             )

    stale_bytes = File.read!(record_path(authority_root, victim))

    assert :ok =
             AuthorityStore.acknowledged_compare_and_delete(victim, original, name: @loss_store)

    assert File.regular?(ctx.ledger_path <> ".initialized")
    stop_supervised!(@loss_store)

    File.rm!(ctx.ledger_path)
    File.write!(record_path(authority_root, victim), stale_bytes)
    File.chmod!(record_path(authority_root, victim), 0o600)

    start_supervised!({AuthorityStore, store_opts})

    assert {:ok, %{status: :failed, reason: :revocation_ledger_missing}} =
             AuthorityStore.hydration_status(name: @loss_store)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_get(victim, name: @loss_store)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_compare_and_create(
               "cap_unrelated_after_ledger_loss",
               :absent,
               Record.new("cap_unrelated_after_ledger_loss", %{}),
               name: @loss_store
             )

    refute File.exists?(ctx.ledger_path)
  end

  @tag spec: "SSEC-010"
  test "security regression: a valid pre-marker ledger is anchored during upgrade", ctx do
    authority_root = authority_root(ctx.fixture_root, "upgrade")
    store_opts = authority_store_opts(@upgrade_store, authority_root, ctx.ledger_path)
    capability_id = "cap_pre_marker_upgrade"
    marker_path = ctx.ledger_path <> ".initialized"

    start_supervised!({AuthorityStore, store_opts})

    assert {:ok, %Record{}} =
             AuthorityStore.acknowledged_compare_and_create(
               capability_id,
               :absent,
               Record.new(capability_id, %{"scope" => "upgrade"}),
               name: @upgrade_store
             )

    stop_supervised!(@upgrade_store)
    File.rm!(marker_path)
    start_supervised!({AuthorityStore, store_opts})

    assert {:ok, %{status: :ready}} = AuthorityStore.hydration_status(name: @upgrade_store)

    assert {:ok, %Record{data: %{"scope" => "upgrade"}}} =
             AuthorityStore.authoritative_get(capability_id, name: @upgrade_store)

    assert File.regular?(marker_path)
    assert Bitwise.band(File.stat!(marker_path).mode, 0o777) == 0o600
  end

  @tag spec: "SSEC-010"
  test "security regression: a malformed initialization marker fails hydration closed", ctx do
    authority_root = authority_root(ctx.fixture_root, "marker")
    store_opts = authority_store_opts(@marker_store, authority_root, ctx.ledger_path)
    capability_id = "cap_marker_authentication"
    marker_path = ctx.ledger_path <> ".initialized"

    start_supervised!({AuthorityStore, store_opts})

    assert {:ok, %Record{}} =
             AuthorityStore.acknowledged_compare_and_create(
               capability_id,
               :absent,
               Record.new(capability_id, %{}),
               name: @marker_store
             )

    stop_supervised!(@marker_store)
    File.write!(marker_path, "{}")
    File.chmod!(marker_path, 0o600)
    start_supervised!({AuthorityStore, store_opts})

    assert {:ok, %{status: :failed, reason: :revocation_ledger_marker_malformed}} =
             AuthorityStore.hydration_status(name: @marker_store)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_get(capability_id, name: @marker_store)
  end

  @tag spec: "SSEC-010"
  test "security regression: authority roots sharing a ledger retain every successful revocation",
       ctx do
    entries =
      @shared_store_names
      |> Enum.with_index(1)
      |> Enum.map(fn {name, index} ->
        authority_root = authority_root(ctx.fixture_root, "writer-#{index}")
        store_opts = authority_store_opts(name, authority_root, ctx.ledger_path)
        capability_id = "cap_shared_ledger_#{index}"

        start_supervised!({AuthorityStore, store_opts})

        assert {:ok, %Record{generation: 1} = stored} =
                 AuthorityStore.acknowledged_compare_and_create(
                   capability_id,
                   :absent,
                   Record.new(capability_id, %{
                     "writer" => index,
                     "contention_payload" => @contention_payload
                   }),
                   name: name
                 )

        %{
          id: capability_id,
          name: name,
          stored: stored,
          path: record_path(authority_root, capability_id),
          stale_bytes: File.read!(record_path(authority_root, capability_id))
        }
      end)

    ready_ref = make_ref()
    release_ref = make_ref()
    parent = self()

    tasks =
      Enum.map(entries, fn entry ->
        Task.async(fn ->
          send(parent, {ready_ref, self()})

          receive do
            ^release_ref ->
              AuthorityStore.acknowledged_compare_and_delete(entry.id, entry.stored,
                name: entry.name
              )
          end
        end)
      end)

    contenders = await_contenders(ready_ref, length(entries), [])
    Enum.each(contenders, &send(&1, release_ref))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.all?(results, &(&1 in [:ok, {:error, :outcome_unknown}])), inspect(results)

    successfully_revoked =
      entries
      |> Enum.zip(results)
      |> Enum.flat_map(fn
        {entry, :ok} -> [entry]
        {_entry, {:error, :outcome_unknown}} -> []
      end)

    assert length(successfully_revoked) > 1

    Enum.each(successfully_revoked, fn entry ->
      File.write!(entry.path, entry.stale_bytes)
      File.chmod!(entry.path, 0o600)
    end)

    Enum.each(successfully_revoked, fn entry ->
      assert {:error, :not_found} =
               AuthorityStore.authoritative_get(entry.id, name: entry.name)
    end)
  end

  defp await_contenders(_ready_ref, 0, contenders), do: contenders

  defp await_contenders(ready_ref, remaining, contenders) do
    receive do
      {^ready_ref, pid} when is_pid(pid) ->
        await_contenders(ready_ref, remaining - 1, [pid | contenders])
    after
      10_000 -> flunk("timed out waiting for revocation contenders")
    end
  end

  defp authority_store_opts(name, authority_root, ledger_path) do
    [
      name: name,
      namespace: "capabilities",
      backend_opts: [
        base_dir: authority_root,
        record_auth_key: @record_auth_key,
        revocation_ledger_path: ledger_path
      ]
    ]
  end

  defp authority_root(fixture_root, name) do
    path = Path.join([fixture_root, "authorities", name])
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp record_path(authority_root, capability_id) do
    namespace_digest = digest(<<1, "capabilities">>)
    key_digest = digest(<<2, capability_id::binary>>)
    Path.join([authority_root, "ns_" <> namespace_digest, key_digest <> ".json"])
  end

  defp digest(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
