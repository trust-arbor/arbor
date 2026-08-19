defmodule Arbor.Security.ApplicationStartProfileTest do
  @moduledoc """
  P1C-A: KernelRuntime `:activation_only` omits Security's BufferedStore
  children. CapabilityStore still starts with empty in-memory state.
  Persistent SystemAuthority first-boot without the signing-keys store
  stays in memory. `:full` keeps today's named stores.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestBootstrap

  @named_stores [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers
  ]

  setup do
    originals = %{
      start_children: Application.get_env(:arbor_security, :start_children),
      system_authority_mode: Application.get_env(:arbor_security, :system_authority_mode),
      kernel_runtime: Application.fetch_env(:arbor_kernel, :kernel_runtime)
    }

    on_exit(fn -> restore_security_app(originals) end)
    :ok
  end

  test "activation_only omits named BufferedStore children and still starts CapabilityStore" do
    restart_security!(:activation_only)

    Enum.each(@named_stores, fn name ->
      assert Process.whereis(name) == nil
    end)

    refute_named_store_child_ids()

    assert Process.whereis(CapabilityStore)
    assert Process.whereis(Registry)
    assert Process.whereis(SystemAuthority)

    stats = CapabilityStore.stats()
    assert stats.active_capabilities == 0
  end

  test "activation_only with persistent system authority starts without named stores" do
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_security!(:activation_only)

    Enum.each(@named_stores, fn name ->
      assert Process.whereis(name) == nil
    end)

    refute_named_store_child_ids()

    assert Process.whereis(SystemAuthority)
    assert is_binary(SystemAuthority.agent_id())
    assert is_binary(SystemAuthority.public_key())
  end

  test ":full still starts the named BufferedStore children" do
    restart_security!(:full)

    Enum.each(@named_stores, fn name ->
      assert is_pid(Process.whereis(name))
    end)

    assert Process.whereis(CapabilityStore)
    assert Process.whereis(Registry)
    assert Process.whereis(SystemAuthority)
  end

  defp restart_security!(profile) do
    Application.put_env(:arbor_security, :start_children, true)
    put_kernel_runtime(start_profile: profile)

    _ = Application.stop(:arbor_security)
    assert {:ok, _} = Application.ensure_all_started(:arbor_security)
  end

  defp put_kernel_runtime(updates) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []
    value = Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)
    Application.put_env(:arbor_kernel, :kernel_runtime, value)
  end

  defp refute_named_store_child_ids do
    ids =
      Arbor.Security.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> MapSet.new()

    Enum.each(@named_stores, fn name ->
      refute MapSet.member?(ids, name)
    end)
  end

  defp restore_security_app(originals) do
    _ = Application.stop(:arbor_security)

    restore_env(:arbor_security, :start_children, originals.start_children)
    restore_env(:arbor_security, :system_authority_mode, originals.system_authority_mode)

    case originals.kernel_runtime do
      {:ok, value} -> Application.put_env(:arbor_kernel, :kernel_runtime, value)
      :error -> Application.delete_env(:arbor_kernel, :kernel_runtime)
    end

    {:ok, _} = Application.ensure_all_started(:arbor_security)
    _ = TestBootstrap.start!()
    restore_extra_security_test_children()
    :ok
  end

  defp restore_env(_app, key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(_app, key, value), do: Application.put_env(:arbor_security, key, value)

  defp restore_extra_security_test_children do
    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    issuer =
      Supervisor.child_spec(
        {Arbor.Persistence.BufferedStore,
         name: :arbor_security_issuers,
         backend: backend,
         write_mode: :sync,
         collection: "issuers"},
        id: :arbor_security_issuers
      )

    start_security_test_child(issuer)

    signing_authority_owner_token = make_ref()

    for child <- [
          {Arbor.Security.IssuerRegistry, []},
          {Arbor.Security.SigningAuthorityStateOwner,
           broker_token: signing_authority_owner_token},
          {Arbor.Security.SigningAuthorityBroker,
           state_owner_token: signing_authority_owner_token},
          {Arbor.Security.DeliveryReceiptBroker, []}
        ] do
      start_security_test_child(child)
    end
  end

  defp start_security_test_child(spec) do
    child_spec = Supervisor.child_spec(spec, [])

    case Supervisor.start_child(Arbor.Security.Supervisor, child_spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} ->
        raise "unexpected start_security_test_child error: #{inspect(reason)}"
    end
  end
end
