defmodule Arbor.KernelRuntime.BootProfileBindingSecurityRegressionTest do
  @moduledoc """
  Public-boundary security regression for the P1A-2 VM-lifetime boot-profile
  binding. Assertions use Application and KernelRuntime APIs. Attack
  construction stays in this module (Core identity token, closed snapshot
  fixtures, and exact-shape ETS preclaim).
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.KernelRuntime.BootProfileBinding.Core
  alias Arbor.KernelRuntime.BootProfileBinding.Testing

  @moduletag :integration
  @moduletag :slow
  @moduletag :security_regression

  @fixture_dir Path.expand(
                 "../../../../arbor_kernel/test/fixtures/extension_envelopes/v1",
                 __DIR__
               )
  @digest "374dabaf63c89a46a92b87bbf0f2e871330ecfe01eb9a230560137b1a7a18268"
  @installer_key_id "37eb0623867f14c690e51a9e24c55fd98ae4b353a00cd3a37ec953330ddda395"
  @installer_public_key "347f4f2c0221027fb01086e2d5b8ee0264ae43ddb99aea3dacf04ce0331f89b8"
  @platform_public_key "46adc9536b563c36a777199fd7a6c8dc82c4c0e9e7952f123a23d27bf0e74170"
  @platform_key_id "e50fe65c9e59cfefce8bea959c8aac98e31d25922b172f9e60acd43cf5b804bb"
  @installer_seed :crypto.hash(:sha256, "arbor.platform.boot_profile.v1.test-installer-seed")
  @table :arbor_kernel_runtime_boot_profile_binding
  @key :vm_lifetime_identity
  @heir_data :arbor_kernel_runtime_boot_profile_binding
  @signals_children [
    {Arbor.Signals.Store, []},
    {Arbor.Signals.TopicKeys, []},
    {Arbor.Signals.Channels, []},
    {Arbor.Signals.Bus, []},
    {Arbor.Signals.Relay, []}
  ]

  setup do
    config_before = Application.fetch_env(:arbor_kernel, :kernel_runtime)

    on_exit(fn ->
      disable_verify_trace()
      reset_test_clock()
      stop_runtime()
      restore_kernel_runtime(config_before)
      {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
      restore_signals_test_children()
      restore_monitor_test_children()
    end)

    :ok
  end

  test "successful fixture bind publishes the closed snapshot on the public boundary" do
    assert function_exported?(Arbor.KernelRuntime, :boot_profile, 0)
    assert {:ok, snapshot} = Arbor.KernelRuntime.boot_profile()
    assert snapshot["schema"] == "arbor.kernel_runtime.boot_profile_binding.v1"
    assert snapshot["version"] == 1
    assert snapshot["manifest_sha256"] == @digest
    assert snapshot["release_id"] == "arbor.platform.release.1"
    assert snapshot["profile_id"] == "safe_recovery"
    assert snapshot["boot_epoch"] == 1
    assert snapshot["platform_public_key"] == @platform_public_key
    assert snapshot["platform_key_id"] == @platform_key_id
    assert snapshot["payload_digests"] == Envelope.boot_profile_fixture()["payload_digests"]
    assert snapshot["revocation_input_id"] == "revocation.platform.1"
    assert snapshot["valid_from"] == "2026-08-17T00:00:00Z"
    assert snapshot["valid_until"] == "2027-08-17T00:00:00Z"
    assert snapshot["signer_id"] == "installer.arbor"
    assert snapshot["signer_key_id"] == @installer_key_id
    refute Map.has_key?(snapshot, "trusted_signers")
    refute Map.has_key?(snapshot, "now")
    refute Map.has_key?(snapshot, "manifest_bytes")
    assert Process.whereis(Arbor.KernelRuntime.BootProfileBinding)
    assert Process.whereis(Arbor.Common.Supervisor)
    assert Process.whereis(Arbor.Signals.Supervisor)
    assert Process.whereis(Arbor.Monitor.Supervisor)
  end

  test "activation_only starts only the binding owner after a successful bind" do
    stop_runtime()
    put_kernel_runtime(start_profile: :activation_only)
    assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    assert runtime_child_ids() == MapSet.new([Arbor.KernelRuntime.BootProfileBinding])
    refute Process.whereis(Arbor.Common.Supervisor)
    assert {:ok, snapshot} = Arbor.KernelRuntime.boot_profile()
    assert snapshot["manifest_sha256"] == @digest
  end

  test "mutated Application env cannot rebind a live snapshot" do
    assert {:ok, before} = Arbor.KernelRuntime.boot_profile()

    put_kernel_runtime(
      boot_profile: fixture_boot_profile(expected_release_id: "other.release.1")
    )

    assert {:ok, ^before} = Arbor.KernelRuntime.boot_profile()
    assert before["manifest_sha256"] == @digest
  end

  test "security regression: non-owner cannot replace or erase the accepted binding" do
    assert {:ok, original} = Arbor.KernelRuntime.boot_profile()
    table = :arbor_kernel_runtime_boot_profile_binding
    key = :vm_lifetime_identity
    parent = self()
    forged = {key, %{"schema" => "forged"}, :crypto.strong_rand_bytes(32)}

    spawn(fn ->
      results = %{
        insert: catch_ets(fn -> :ets.insert(table, forged) end),
        delete_key: catch_ets(fn -> :ets.delete(table, key) end),
        delete_all: catch_ets(fn -> :ets.delete_all_objects(table) end),
        take: catch_ets(fn -> :ets.take(table, key) end),
        delete_table: catch_ets(fn -> :ets.delete(table) end)
      }

      send(parent, {:attack, results})
    end)

    assert_receive {:attack, results}, 1_000

    Enum.each(results, fn {op, result} ->
      assert result == :rejected, "#{op} #{inspect(result)}"
    end)

    assert {:ok, ^original} = Arbor.KernelRuntime.boot_profile()
    assert original["manifest_sha256"] == @digest
  end

  test "owner death tears down later children and same-identity recovery re-verifies" do
    owner = child_pid(Arbor.KernelRuntime.BootProfileBinding)
    common = Process.whereis(Arbor.Common.Supervisor)
    assert is_pid(owner)
    assert is_pid(common)
    owner_ref = Process.monitor(owner)
    common_ref = Process.monitor(common)

    with_verify_trace(fn ->
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
      assert_receive {:DOWN, ^common_ref, :process, ^common, _}, 1_000

      await_true(fn ->
        new_owner = child_pid(Arbor.KernelRuntime.BootProfileBinding)
        new_common = Process.whereis(Arbor.Common.Supervisor)
        is_pid(new_owner) and new_owner != owner and is_pid(new_common) and new_common != common
      end)

      assert_verify_trace()
    end)

    assert {:ok, snapshot} = Arbor.KernelRuntime.boot_profile()
    assert snapshot["manifest_sha256"] == @digest
  end

  test "same-identity application restart re-verifies and preserves the digest" do
    stop_runtime()

    with_verify_trace(fn ->
      assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
      await_true(fn -> is_pid(Process.whereis(Arbor.KernelRuntime.BootProfileBinding)) end)
      assert_verify_trace()
    end)

    assert {:ok, snapshot} = Arbor.KernelRuntime.boot_profile()
    assert snapshot["manifest_sha256"] == @digest
  end

  test "changed-identity application restart fails closed and keeps the frozen digest" do
    stop_runtime()
    {manifest_bytes, signature_bytes, digest} = signed_epoch(2)

    put_kernel_runtime(
      start_profile: :full,
      boot_profile:
        fixture_boot_profile(
          min_boot_epoch: 2,
          manifest_bytes: manifest_bytes,
          signature_bytes: signature_bytes
        )
    )

    with_verify_trace(fn ->
      assert {:error,
              {:arbor_kernel_runtime, {reason, {Arbor.KernelRuntime.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_kernel_runtime)

      assert failed_child?(reason, :rebind_rejected)
      refute_verify_trace()
    end)

    refute Process.whereis(Arbor.KernelRuntime.Supervisor)
    refute Process.whereis(Arbor.Common.Supervisor)
    assert {:error, :not_bound} = Arbor.KernelRuntime.boot_profile()
    assert_frozen_digest()
    refute digest == @digest
  end

  test "owner death after mutated env fails closed without replacing the freeze" do
    owner = child_pid(Arbor.KernelRuntime.BootProfileBinding)
    common = Process.whereis(Arbor.Common.Supervisor)
    supervisor = Process.whereis(Arbor.KernelRuntime.Supervisor)
    owner_ref = Process.monitor(owner)
    common_ref = Process.monitor(common)
    sup_ref = Process.monitor(supervisor)

    put_kernel_runtime(
      boot_profile: fixture_boot_profile(expected_release_id: "other.release.1")
    )

    with_verify_trace(fn ->
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
      assert_receive {:DOWN, ^common_ref, :process, ^common, _}, 1_000
      assert_receive {:DOWN, ^sup_ref, :process, ^supervisor, _}, 5_000
      refute Process.whereis(Arbor.Common.Supervisor)
      refute_verify_trace()
    end)

    assert {:error, :not_bound} = Arbor.KernelRuntime.boot_profile()
    assert_frozen_digest()
  end

  test "owner death after unbounded stage-zero fails closed without replacing the freeze" do
    owner = child_pid(Arbor.KernelRuntime.BootProfileBinding)
    common = Process.whereis(Arbor.Common.Supervisor)
    supervisor = Process.whereis(Arbor.KernelRuntime.Supervisor)
    owner_ref = Process.monitor(owner)
    common_ref = Process.monitor(common)
    sup_ref = Process.monitor(supervisor)
    signer = hd(fixture_boot_profile()[:trusted_signers])

    put_kernel_runtime(
      boot_profile: fixture_boot_profile(trusted_signers: List.duplicate(signer, 33))
    )

    with_verify_trace(fn ->
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
      assert_receive {:DOWN, ^common_ref, :process, ^common, _}, 1_000
      assert_receive {:DOWN, ^sup_ref, :process, ^supervisor, _}, 5_000
      refute Process.whereis(Arbor.Common.Supervisor)
      refute_verify_trace()
    end)

    assert {:error, :not_bound} = Arbor.KernelRuntime.boot_profile()
    assert_frozen_digest()
  end

  test "malformed namespace fails closed as a binding error and keeps the freeze" do
    stop_runtime()
    Application.put_env(:arbor_kernel, :kernel_runtime, :not_a_keyword)

    assert {:error,
            {:arbor_kernel_runtime, {reason, {Arbor.KernelRuntime.Application, :start, _}}}} =
             Application.ensure_all_started(:arbor_kernel_runtime)

    assert reason == {:boot_profile_binding_failed, :malformed_stage_zero}
    refute Process.whereis(Arbor.KernelRuntime.Supervisor)
    assert {:error, :not_bound} = Arbor.KernelRuntime.boot_profile()
    assert_frozen_digest()
  end

  @tag timeout: 240_000
  test "peer first-bind failures fail closed before nested applications" do
    {bad_platform_manifest, bad_platform_signature, _} =
      signed_manifest(%{
        Envelope.boot_profile_fixture()
        | "platform_key_id" => String.duplicate("00", 32)
      })

    forged = forged_signature_bytes()
    non_canonical = fixture_manifest_bytes() <> "\n"

    cases = [
      {:absent, [start_profile: :activation_only], :absent},
      {:malformed,
       [
         start_profile: :activation_only,
         boot_profile: malformed_stage_zero_boot_profile(now: "2026-08-17T00:00:00Z")
       ], :malformed_stage_zero},
      {:unbounded_signers,
       [
         start_profile: :activation_only,
         boot_profile:
           fixture_boot_profile(
             trusted_signers: List.duplicate(hd(fixture_boot_profile()[:trusted_signers]), 33)
           )
       ], :malformed_stage_zero},
      {:unbounded_id,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(expected_release_id: String.duplicate("a", 129))
       ], :malformed_stage_zero},
      {:non_canonical,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(manifest_bytes: non_canonical)
       ], :non_canonical_bytes},
      {:forged,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(signature_bytes: forged)
       ], :signature_mismatch},
      {:untrusted,
       [start_profile: :activation_only, boot_profile: fixture_boot_profile(trusted_signers: [])],
       :untrusted_signer},
      {:signer_key_id,
       [
         start_profile: :activation_only,
         boot_profile:
           fixture_boot_profile(
             trusted_signers: [
               %{
                 "signer_id" => "installer.arbor",
                 "key_id" => @installer_key_id,
                 "public_key" => @platform_public_key
               }
             ]
           )
       ], :signer_key_id_mismatch},
      {:platform_key_id,
       [
         start_profile: :activation_only,
         boot_profile:
           fixture_boot_profile(
             manifest_bytes: bad_platform_manifest,
             signature_bytes: bad_platform_signature
           )
       ], :platform_key_id_mismatch},
      {:stale_epoch,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(min_boot_epoch: 2)
       ], :stale_epoch},
      {:signer_revoked,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(revoked_signer_key_ids: [@installer_key_id])
       ], :signer_revoked},
      {:platform_revoked,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(revoked_platform_key_ids: [@platform_key_id])
       ], :platform_key_revoked},
      {:release,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(expected_release_id: "arbor.platform.release.2")
       ], :release_mismatch},
      {:profile,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(expected_profile_id: "other_profile")
       ], :profile_mismatch},
      {:revocation_input,
       [
         start_profile: :activation_only,
         boot_profile: fixture_boot_profile(expected_revocation_input_id: "revocation.platform.2")
       ], :revocation_input_mismatch},
      {:payload,
       [
         start_profile: :activation_only,
         boot_profile:
           fixture_boot_profile(
             expected_payload_digests: [
               %{"id" => "payload.kernel", "sha256" => String.duplicate("33", 32)},
               %{"id" => "payload.kernel_runtime", "sha256" => String.duplicate("22", 32)}
             ]
           )
       ], :payload_mismatch}
    ]

    Enum.each(cases, fn {_name, runtime, expected} ->
      with_peer(fn control ->
        put_peer_runtime(control, runtime)
        assert_peer_bind_failed(control, expected)
        refute_peer_started(control, :activation_only)
      end)
    end)

    with_peer(fn control ->
      put_peer_runtime(
        control,
        start_profile: :full,
        boot_profile: fixture_boot_profile(signature_bytes: forged)
      )

      assert_peer_bind_failed(control, :signature_mismatch)
      refute_peer_started(control, :full)
    end)
  end

  test "peer clock seam proves not-yet-valid and expired first-bind failures" do
    with_peer(fn control ->
      peer_put_now(control, "2026-08-16T23:59:59Z")

      put_peer_runtime(control,
        start_profile: :activation_only,
        boot_profile: fixture_boot_profile()
      )

      assert_peer_bind_failed(control, :not_yet_valid)
    end)

    with_peer(fn control ->
      peer_put_now(control, "2027-08-17T00:00:01Z")

      put_peer_runtime(control,
        start_profile: :activation_only,
        boot_profile: fixture_boot_profile()
      )

      assert_peer_bind_failed(control, :expired)
    end)
  end

  test "a fresh peer VM may bind a different identity while the parent claim stays" do
    {manifest_bytes, signature_bytes, digest} = signed_epoch(2)
    assert digest != @digest

    with_peer(fn control ->
      put_peer_runtime(control,
        start_profile: :activation_only,
        boot_profile:
          fixture_boot_profile(
            min_boot_epoch: 2,
            manifest_bytes: manifest_bytes,
            signature_bytes: signature_bytes
          )
      )

      assert {:ok, _} =
               peer_call(control, Application, :ensure_all_started, [:arbor_kernel_runtime])

      assert peer_call(control, :erlang, :function_exported, [
               Arbor.KernelRuntime,
               :boot_profile,
               0
             ])

      assert {:ok, snapshot} = peer_call(control, Arbor.KernelRuntime, :boot_profile, [])
      assert snapshot["manifest_sha256"] == digest
      assert snapshot["boot_epoch"] == 2
    end)

    assert {:ok, parent} = Arbor.KernelRuntime.boot_profile()
    assert parent["manifest_sha256"] == @digest
  end

  test "security regression: init-owned forged exact-shape preclaim is independently verified and rejected" do
    forged = forged_closed_snapshot()
    assert {:ok, ^forged} = Core.admit_snapshot(forged)
    assert {:ok, token} = Core.identity_token(admitted_stage_zero())
    assert byte_size(token) == 32

    with_peer(fn control ->
      put_peer_runtime(control,
        start_profile: :activation_only,
        boot_profile: fixture_boot_profile()
      )

      ensure_peer_test_module!(control)
      owner = peer_call(control, __MODULE__, :preclaim_init_owned_binding!, [forged, token])
      info = peer_call(control, __MODULE__, :binding_table_info, [])
      assert owner == peer_call(control, Process, :whereis, [:init])
      assert info.owner == owner
      assert info.type == :set
      assert info.protection == :protected
      assert info.size == 1
      assert info.name == @table
      assert {:ok, ^forged, ^token} = peer_call(control, __MODULE__, :frozen_row, [])

      assert_peer_bind_failed(control, :corrupt_slot)
      refute_peer_started(control, :activation_only)
      assert peer_call(control, Arbor.KernelRuntime, :boot_profile, []) == {:error, :not_bound}
      assert {:ok, ^forged, ^token} = peer_call(control, __MODULE__, :frozen_row, [])
    end)
  end

  test "structurally exact genuine preclaim is admitted after independent verification" do
    genuine = genuine_snapshot()
    assert {:ok, ^genuine} = Core.admit_snapshot(genuine)
    assert {:ok, token} = Core.identity_token(admitted_stage_zero())
    assert byte_size(token) == 32

    with_peer(fn control ->
      put_peer_runtime(control,
        start_profile: :activation_only,
        boot_profile: fixture_boot_profile()
      )

      ensure_peer_test_module!(control)
      owner = peer_call(control, __MODULE__, :preclaim_init_owned_binding!, [genuine, token])
      assert owner == peer_call(control, Process, :whereis, [:init])

      assert {:ok, _} =
               peer_call(control, Application, :ensure_all_started, [:arbor_kernel_runtime])

      assert {:ok, snapshot} = peer_call(control, Arbor.KernelRuntime, :boot_profile, [])
      assert snapshot == genuine
      assert snapshot["manifest_sha256"] == @digest
    end)
  end

  test "same-identity restore fails closed when the signed envelope is expired" do
    with_peer(fn control ->
      put_peer_runtime(control,
        start_profile: :activation_only,
        boot_profile: fixture_boot_profile()
      )

      assert {:ok, _} =
               peer_call(control, Application, :ensure_all_started, [:arbor_kernel_runtime])

      assert {:ok, snapshot} = peer_call(control, Arbor.KernelRuntime, :boot_profile, [])
      assert snapshot["manifest_sha256"] == @digest
      :ok = peer_call(control, Application, :stop, [:arbor_kernel_runtime])

      ensure_peer_test_module!(control)
      assert {:ok, frozen, token} = peer_call(control, __MODULE__, :frozen_row, [])
      assert frozen["manifest_sha256"] == @digest
      assert byte_size(token) == 32
      assert peer_call(control, __MODULE__, :binding_table_owner, []) ==
               peer_call(control, Process, :whereis, [:init])

      peer_put_now(control, "2027-08-17T00:00:01Z")
      assert_peer_bind_failed(control, :expired)
      refute_peer_started(control, :activation_only)
      assert peer_call(control, Arbor.KernelRuntime, :boot_profile, []) == {:error, :not_bound}
      assert {:ok, ^frozen, ^token} = peer_call(control, __MODULE__, :frozen_row, [])
    end)
  end

  test "security regression: boot_profile does not publish while blocked restore then expires" do
    stop_runtime()
    put_kernel_runtime(start_profile: :activation_only)
    Testing.block_now()
    parent = self()

    starter =
      spawn(fn ->
        send(parent, {:started, Application.ensure_all_started(:arbor_kernel_runtime)})
      end)

    starter_ref = Process.monitor(starter)
    await_true(fn -> Testing.now_waiting?() end, 5_000)

    reader =
      spawn(fn ->
        send(parent, {:boot_profile, Arbor.KernelRuntime.boot_profile()})
      end)

    reader_ref = Process.monitor(reader)
    refute_receive {:boot_profile, _}, 300
    refute_receive {:started, _}, 0
    assert Process.alive?(reader)
    assert Process.alive?(starter)

    Testing.unblock_now("2027-08-17T00:00:01Z")

    assert_receive {:started,
                    {:error,
                     {:arbor_kernel_runtime,
                      {reason, {Arbor.KernelRuntime.Application, :start, _}}}}},
                   5_000

    assert failed_child?(reason, :expired)
    assert_receive {:boot_profile, {:error, :not_bound}}, 5_000
    assert_receive {:DOWN, ^starter_ref, :process, ^starter, _}, 1_000
    assert_receive {:DOWN, ^reader_ref, :process, ^reader, _}, 1_000
    refute Process.whereis(Arbor.KernelRuntime.Supervisor)
    assert {:error, :not_bound} = Arbor.KernelRuntime.boot_profile()
    assert_frozen_digest()
  end

  test "lib identity slot has a single put site and no erase" do
    binding =
      Path.expand("../../../lib/arbor/kernel_runtime/boot_profile_binding.ex", __DIR__)

    src = File.read!(binding)
    assert src =~ "defp commit_first("
    assert src =~ ":ets.new(@table"
    assert src =~ ":ets.insert_new("
    refute src =~ ":persistent_term.put"
    refute src =~ ":persistent_term.erase"
    refute src =~ ":ets.insert("
    refute src =~ ":ets.delete"
    refute src =~ ":ets.take"
    refute src =~ ":ets.give_away"

    lib_root = Path.expand("../../../lib", __DIR__)

    put_files =
      lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        contents = File.read!(path)

        String.contains?(contents, ":ets.new(@table") or
          (String.contains?(contents, "arbor_kernel_runtime_boot_profile_binding") and
             String.contains?(contents, ":ets.new"))
      end)

    assert put_files == [binding]
  end

  @doc false
  def preclaim_init_owned_binding!(snapshot, token) do
    init = Process.whereis(:init)
    parent = self()

    creator =
      spawn(fn ->
        table =
          :ets.new(@table, [
            :named_table,
            :set,
            :protected,
            {:heir, init, @heir_data},
            read_concurrency: true
          ])

        true = :ets.insert_new(table, {@key, snapshot, token})
        send(parent, {:preclaim_ready, self()})

        receive do
          :exit -> :ok
        end
      end)

    receive do
      {:preclaim_ready, ^creator} -> :ok
    after
      1_000 -> raise "preclaim creator did not become ready"
    end

    ref = Process.monitor(creator)
    send(creator, :exit)

    receive do
      {:DOWN, ^ref, :process, ^creator, _} -> :ok
    after
      1_000 -> raise "preclaim creator did not exit"
    end

    :ets.info(@table, :owner)
  end

  @doc false
  def frozen_row do
    case :ets.lookup(@table, @key) do
      [{@key, snapshot, token}] -> {:ok, snapshot, token}
      _ -> :absent
    end
  end

  @doc false
  def binding_table_owner do
    :ets.info(@table, :owner)
  end

  @doc false
  def binding_table_info do
    %{
      owner: :ets.info(@table, :owner),
      heir: :ets.info(@table, :heir),
      type: :ets.info(@table, :type),
      protection: :ets.info(@table, :protection),
      size: :ets.info(@table, :size),
      name: :ets.info(@table, :name)
    }
  end

  defp catch_ets(fun) do
    try do
      {:returned, fun.()}
    rescue
      ArgumentError -> :rejected
    end
  end

  defp fixture_manifest_bytes,
    do: File.read!(Path.join(@fixture_dir, "boot_profile_manifest.json"))

  defp fixture_signature_bytes,
    do: File.read!(Path.join(@fixture_dir, "boot_profile_signature.json"))

  defp fixture_boot_profile(overrides \\ []) do
    Keyword.merge(
      [
        manifest_bytes: fixture_manifest_bytes(),
        signature_bytes: fixture_signature_bytes(),
        trusted_signers: [
          %{
            "signer_id" => "installer.arbor",
            "key_id" => @installer_key_id,
            "public_key" => @installer_public_key
          }
        ],
        expected_release_id: "arbor.platform.release.1",
        expected_profile_id: "safe_recovery",
        expected_revocation_input_id: "revocation.platform.1",
        expected_payload_digests: Envelope.boot_profile_fixture()["payload_digests"],
        min_boot_epoch: 1,
        revoked_signer_key_ids: [],
        revoked_platform_key_ids: []
      ],
      overrides
    )
  end

  defp malformed_stage_zero_boot_profile(overrides) do
    fixture_boot_profile(overrides)
  end

  defp admitted_stage_zero(overrides \\ []) do
    kw = fixture_boot_profile(overrides)

    %{
      "manifest_bytes" => Keyword.fetch!(kw, :manifest_bytes),
      "signature_bytes" => Keyword.fetch!(kw, :signature_bytes),
      "trusted_signers" => Keyword.fetch!(kw, :trusted_signers),
      "expected_release_id" => Keyword.fetch!(kw, :expected_release_id),
      "expected_profile_id" => Keyword.fetch!(kw, :expected_profile_id),
      "expected_revocation_input_id" => Keyword.fetch!(kw, :expected_revocation_input_id),
      "expected_payload_digests" => Keyword.fetch!(kw, :expected_payload_digests),
      "min_boot_epoch" => Keyword.fetch!(kw, :min_boot_epoch),
      "revoked_signer_key_ids" => Keyword.fetch!(kw, :revoked_signer_key_ids),
      "revoked_platform_key_ids" => Keyword.fetch!(kw, :revoked_platform_key_ids)
    }
  end

  defp genuine_snapshot do
    %{
      "schema" => "arbor.kernel_runtime.boot_profile_binding.v1",
      "version" => 1,
      "manifest_sha256" => @digest,
      "release_id" => "arbor.platform.release.1",
      "profile_id" => "safe_recovery",
      "boot_epoch" => 1,
      "platform_public_key" => @platform_public_key,
      "platform_key_id" => @platform_key_id,
      "payload_digests" => Envelope.boot_profile_fixture()["payload_digests"],
      "revocation_input_id" => "revocation.platform.1",
      "valid_from" => "2026-08-17T00:00:00Z",
      "valid_until" => "2027-08-17T00:00:00Z",
      "signer_id" => "installer.arbor",
      "signer_key_id" => @installer_key_id
    }
  end

  defp forged_closed_snapshot do
    %{genuine_snapshot() | "manifest_sha256" => String.duplicate("00", 32)}
  end

  defp forged_signature_bytes do
    signature = Envelope.boot_profile_signature_fixture()
    last = String.last(signature["signature"])
    flipped = if last == "0", do: "1", else: "0"

    forged = %{
      signature
      | "signature" => String.slice(signature["signature"], 0, 127) <> flipped
    }

    {:ok, bytes} = Envelope.boot_profile_signature_canonical_json(forged)
    bytes
  end

  defp signed_epoch(epoch) do
    signed_manifest(%{Envelope.boot_profile_fixture() | "boot_epoch" => epoch})
  end

  defp signed_manifest(manifest) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519, @installer_seed)
    assert Base.encode16(public_key, case: :lower) == @installer_public_key
    {:ok, manifest_bytes} = Envelope.boot_profile_canonical_json(manifest)
    {:ok, digest} = Envelope.boot_profile_digest_of(manifest)

    unsigned = %{
      "schema" => Envelope.boot_profile_signature_schema(),
      "version" => Envelope.boot_profile_version(),
      "domain" => Envelope.boot_profile_schema(),
      "manifest_encoding" => Envelope.boot_profile_payload_encoding(),
      "manifest_sha256" => digest,
      "signer_id" => "installer.arbor",
      "key_id" => @installer_key_id,
      "signature" => String.duplicate("00", 64)
    }

    message =
      Enum.join(
        [
          unsigned["domain"],
          unsigned["schema"],
          unsigned["signer_id"],
          unsigned["key_id"],
          unsigned["manifest_sha256"]
        ],
        <<0>>
      )

    hex =
      Base.encode16(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519]), case: :lower)

    {:ok, signature_bytes} =
      Envelope.boot_profile_signature_canonical_json(%{unsigned | "signature" => hex})

    {manifest_bytes, signature_bytes, digest}
  end

  defp put_kernel_runtime(updates) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []

    merged =
      Enum.reduce(updates, current, fn
        {:boot_profile, profile}, acc -> Keyword.put(acc, :boot_profile, profile)
        {key, value}, acc -> Keyword.put(acc, key, value)
      end)

    Application.put_env(:arbor_kernel, :kernel_runtime, merged)
  end

  defp restore_kernel_runtime({:ok, value}) do
    Application.put_env(:arbor_kernel, :kernel_runtime, value)
  end

  defp restore_kernel_runtime(:error) do
    Application.delete_env(:arbor_kernel, :kernel_runtime)
  end

  defp runtime_child_ids do
    Arbor.KernelRuntime.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
    |> MapSet.new()
  end

  defp child_pid(id) do
    Arbor.KernelRuntime.Supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp stop_runtime do
    case Application.stop(:arbor_kernel_runtime) do
      :ok -> :ok
      {:error, {:not_started, :arbor_kernel_runtime}} -> :ok
    end
  end

  defp restore_signals_test_children do
    Enum.each(@signals_children, fn {module, _opts} = child ->
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)

        {:error, _reason} ->
          :ok
      end
    end)
  end

  defp restore_monitor_test_children do
    Enum.each([Arbor.Monitor.MetricsStore, Arbor.Monitor.Poller], fn module ->
      case Supervisor.start_child(Arbor.Monitor.Supervisor, {module, []}) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          :ok = Supervisor.delete_child(Arbor.Monitor.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Monitor.Supervisor, {module, []})

        {:error, _reason} ->
          :ok
      end
    end)
  end

  defp failed_child?(reason, :rebind_rejected) do
    match?(
      {:shutdown,
       {:failed_to_start_child, Arbor.KernelRuntime.BootProfileBinding,
        {:boot_profile_rebind_rejected, _, _}}},
      reason
    )
  end

  defp failed_child?(reason, expected) when is_atom(expected) do
    match?(
      {:shutdown,
       {:failed_to_start_child, Arbor.KernelRuntime.BootProfileBinding,
        {:boot_profile_binding_failed, ^expected}}},
      reason
    )
  end

  defp assert_frozen_digest do
    assert {:ok, snapshot, token} = frozen_row()
    assert snapshot["manifest_sha256"] == @digest
    assert is_binary(token) and byte_size(token) == 32
  end

  defp assert_verify_trace do
    assert_receive {:trace, _, :call,
                    {Arbor.Contracts.Extension.Envelope, :verify_boot_profile, _}},
                   1_000
  end

  defp refute_verify_trace do
    refute_received {:trace, _, :call,
                     {Arbor.Contracts.Extension.Envelope, :verify_boot_profile, _}}
  end

  defp ensure_peer_test_module!(control) do
    case peer_call(control, Code, :ensure_loaded, [__MODULE__]) do
      {:module, _} ->
        :ok

      _ ->
        case :code.get_object_code(__MODULE__) do
          {mod, binary, filename} ->
            {:module, ^mod} = peer_call(control, :code, :load_binary, [mod, filename, binary])
            :ok

          :error ->
            flunk("test module not loadable on peer")
        end
    end
  end

  defp with_verify_trace(fun) do
    :erlang.trace_pattern(
      {Arbor.Contracts.Extension.Envelope, :verify_boot_profile, 3},
      true,
      []
    )

    :erlang.trace(:new, true, [:call, {:tracer, self()}])

    try do
      fun.()
    after
      disable_verify_trace()
      flush_traces()
    end
  end

  defp reset_test_clock do
    if function_exported?(Testing, :reset_clock, 0) do
      Testing.reset_clock()
    else
      :ok
    end
  end

  defp disable_verify_trace do
    try do
      :erlang.trace(:new, false, [:call])
    rescue
      _ -> :ok
    end

    :erlang.trace_pattern(
      {Arbor.Contracts.Extension.Envelope, :verify_boot_profile, 3},
      false,
      []
    )

    :ok
  end

  defp flush_traces do
    receive do
      {:trace, _, _, _} -> flush_traces()
      {:trace, _, _, _, _} -> flush_traces()
    after
      0 -> :ok
    end
  end

  defp await_true(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_true_loop(fun, deadline)
  end

  defp await_true_loop(fun, deadline) do
    if fun.() do
      true
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk("condition not met before deadline")
      else
        receive do
        after
          min(remaining, 10) -> await_true_loop(fun, deadline)
        end
      end
    end
  end

  defp with_peer(fun) do
    control = start_peer!()

    try do
      prepare_peer!(control)
      fun.(control)
    after
      stop_peer(control)
    end
  end

  defp start_peer! do
    case :peer.start_link(%{connection: :standard_io, wait_boot: 30_000}) do
      {:ok, control} when is_pid(control) -> control
      {:ok, control, _node} -> control
      other -> flunk("peer start failed: #{inspect(other)}")
    end
  end

  defp stop_peer(control) do
    try do
      :peer.stop(control)
    catch
      _, _ -> :ok
    end
  end

  defp prepare_peer!(control) do
    _ = peer_call(control, :code, :add_paths, [:code.get_path()])
    {:ok, _} = peer_call(control, :application, :ensure_all_started, [:elixir])
    {:ok, _} = peer_call(control, :application, :ensure_all_started, [:crypto])

    Enum.each(Application.loaded_applications(), fn {app, _desc, _vsn} ->
      Enum.each(Application.get_all_env(app), fn {key, value} ->
        :ok = peer_call(control, Application, :put_env, [app, key, value, [persistent: true]])
      end)
    end)

    :ok
  end

  defp put_peer_runtime(control, runtime) do
    :ok =
      peer_call(control, Application, :put_env, [
        :arbor_kernel,
        :kernel_runtime,
        runtime,
        [persistent: true]
      ])
  end

  defp peer_put_now(control, timestamp) do
    {:module, _} =
      peer_call(control, Code, :ensure_loaded, [Arbor.KernelRuntime.BootProfileBinding.Testing])

    :ok =
      peer_call(
        control,
        Arbor.KernelRuntime.BootProfileBinding.Testing,
        :put_now,
        [timestamp]
      )
  end

  defp assert_peer_bind_failed(control, expected) do
    result = peer_call(control, Application, :ensure_all_started, [:arbor_kernel_runtime])

    assert {:error,
            {:arbor_kernel_runtime, {reason, {Arbor.KernelRuntime.Application, :start, _}}}} =
             result

    assert failed_child?(reason, expected),
           "expected #{inspect(expected)} got #{inspect(reason)}"
  end

  defp refute_peer_started(control, :activation_only) do
    assert peer_call(control, Process, :whereis, [Arbor.KernelRuntime.Supervisor]) == nil
  end

  defp refute_peer_started(control, :full) do
    assert peer_call(control, Process, :whereis, [Arbor.KernelRuntime.Supervisor]) == nil
    assert peer_call(control, Process, :whereis, [Arbor.Common.Supervisor]) == nil
    assert peer_call(control, Process, :whereis, [Arbor.Signals.Supervisor]) == nil
    assert peer_call(control, Process, :whereis, [Arbor.Monitor.Supervisor]) == nil
  end

  defp peer_call(control, module, function, args) do
    :peer.call(control, module, function, args, 60_000)
  end
end
