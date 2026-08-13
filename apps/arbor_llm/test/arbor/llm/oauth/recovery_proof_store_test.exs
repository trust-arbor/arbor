defmodule Arbor.LLM.OAuth.RecoveryProofStoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.OAuth.RecoveryProofStore

  setup do
    name = :"recovery-proof-#{System.unique_integer([:positive])}"
    {:ok, pid} = RecoveryProofStore.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    {:ok, store: name, pid: pid}
  end

  test "issue returns a 43-character handle and take is one-shot", %{store: store} do
    deadline = future_deadline()

    assert {:ok, handle} =
             RecoveryProofStore.issue(:openai, "acct", 1, "tok", deadline, store)

    assert RecoveryProofStore.valid_handle?(handle)
    assert RecoveryProofStore.live_count(:openai, store) == 1

    used = %{account_id: "acct", generation: 1, access_token: "tok"}
    assert {:ok, :matched} = RecoveryProofStore.take(:openai, handle, used, store)
    assert {:error, :not_found} = RecoveryProofStore.take(:openai, handle, used, store)
    assert RecoveryProofStore.live_count(:openai, store) == 0
  end

  test "unknown casts fail closed without terminating or dropping issued leases", %{
    store: store,
    pid: pid
  } do
    access = "cast-access-token-secret"
    account = "cast-account-secret"
    deadline = future_deadline()

    assert {:ok, handle} =
             RecoveryProofStore.issue(:openai, account, 3, access, deadline, store)

    :ok = GenServer.cast(pid, {:issue, :openai, account, 3, access, deadline})
    :ok = GenServer.cast(pid, {:unknown, access, account})

    assert Process.alive?(pid)
    assert RecoveryProofStore.live_count(:openai, store) == 1

    status = inspect(:sys.get_status(pid))
    refute status =~ access
    refute status =~ account

    used = %{account_id: account, generation: 3, access_token: access}
    assert {:ok, :matched} = RecoveryProofStore.take(:openai, handle, used, store)
    assert Process.alive?(pid)
  end

  test "an openai handle cannot be consumed via xai and vice versa", %{store: store} do
    deadline = future_deadline()

    assert {:ok, openai_handle} =
             RecoveryProofStore.issue(:openai, "acct", 1, "openai-tok", deadline, store)

    assert {:ok, xai_handle} =
             RecoveryProofStore.issue(:xai, nil, 2, "xai-tok", deadline, store)

    used_openai = %{account_id: "acct", generation: 1, access_token: "openai-tok"}
    used_xai = %{account_id: nil, generation: 2, access_token: "xai-tok"}

    assert {:error, :not_found} =
             RecoveryProofStore.take(:xai, openai_handle, used_openai, store)

    assert {:error, :not_found} = RecoveryProofStore.take(:openai, xai_handle, used_xai, store)
    assert {:ok, :matched} = RecoveryProofStore.take(:openai, openai_handle, used_openai, store)
    assert {:ok, :matched} = RecoveryProofStore.take(:xai, xai_handle, used_xai, store)
  end

  test "token or account field mismatch consumes the lease and returns proof mismatch", %{
    store: store
  } do
    deadline = future_deadline()

    assert {:ok, handle} =
             RecoveryProofStore.issue(:openai, "acct", 4, "tok", deadline, store)

    assert {:error, :oauth_arbor_owned_proof_mismatch} =
             RecoveryProofStore.take(
               :openai,
               handle,
               %{account_id: "acct", generation: 4, access_token: "other-tok"},
               store
             )

    assert {:error, :not_found} =
             RecoveryProofStore.take(
               :openai,
               handle,
               %{account_id: "acct", generation: 4, access_token: "tok"},
               store
             )
  end

  test "discard is idempotent and frees the per-provider cap", %{store: store} do
    deadline = future_deadline()

    handles =
      Enum.map(1..256, fn index ->
        assert {:ok, handle} =
                 RecoveryProofStore.issue(:openai, "acct", index, "tok-#{index}", deadline, store)

        handle
      end)

    assert {:error, :oauth_recovery_proofs_exhausted} =
             RecoveryProofStore.issue(:openai, "acct", 9_999, "tok", deadline, store)

    Enum.each(handles, &assert(:ok = RecoveryProofStore.discard(:openai, &1, store)))
    assert RecoveryProofStore.live_count(:openai, store) == 0

    assert {:ok, _handle} =
             RecoveryProofStore.issue(:openai, "acct", 1, "tok", deadline, store)
  end

  test "issuer process death releases that pid's leases", %{store: store} do
    parent = self()
    deadline = future_deadline()

    issuer =
      spawn(fn ->
        assert {:ok, handle} =
                 RecoveryProofStore.issue(:openai, "acct", 1, "tok", deadline, store)

        send(parent, {:issued, handle})
        Process.sleep(60_000)
      end)

    assert_receive {:issued, _handle}, 1_000
    assert RecoveryProofStore.live_count(:openai, store) == 1
    Process.exit(issuer, :kill)
    wait_until(fn -> RecoveryProofStore.live_count(:openai, store) == 0 end, 1_000)
  end

  test "format_status and get_status never include token or account material", %{
    store: store,
    pid: pid
  } do
    access = "status-access-token-secret"
    refresh = "status-refresh-token-secret"
    account = "status-account-secret"
    deadline = future_deadline()

    assert {:ok, _handle} =
             RecoveryProofStore.issue(:openai, account, 7, access, deadline, store)

    status = :sys.get_status(pid)
    rendered = inspect(status)
    refute rendered =~ access
    refute rendered =~ refresh
    refute rendered =~ account
    assert rendered =~ "redacted"

    formatted =
      RecoveryProofStore.format_status(%{
        state: :sys.get_state(pid),
        reason: {:exit, access},
        message: {:call, refresh},
        log: [{:event, account}],
        other: "public"
      })

    assert formatted.state == %{openai: 1, xai: 0, records: :redacted}
    assert formatted.reason == "#Arbor.LLM.OAuth.RecoveryProofStore<redacted>"
    assert formatted.message == "#Arbor.LLM.OAuth.RecoveryProofStore<redacted>"
    assert formatted.log == "#Arbor.LLM.OAuth.RecoveryProofStore<redacted>"
    assert formatted.other == "public"
    refute inspect(formatted) =~ access
    refute inspect(formatted) =~ account
  end

  test "a down store fails issue and take closed and discard stays ok" do
    Process.flag(:trap_exit, true)
    name = :"recovery-proof-down-#{System.unique_integer([:positive])}"
    {:ok, pid} = RecoveryProofStore.start_link(name: name)
    Process.exit(pid, :kill)
    wait_until(fn -> not Process.alive?(pid) end, 1_000)

    assert {:error, :oauth_recovery_lease_unavailable} =
             RecoveryProofStore.issue(:openai, "acct", 1, "tok", future_deadline(), name)

    assert {:error, :oauth_recovery_lease_unavailable} =
             RecoveryProofStore.take(
               :openai,
               String.duplicate("a", 43),
               %{account_id: "acct", generation: 1, access_token: "tok"},
               name
             )

    assert :ok = RecoveryProofStore.discard(:openai, String.duplicate("a", 43), name)
    assert RecoveryProofStore.live_count(:openai, name) == 0
  end

  test "live_count returns only a non-negative integer", %{store: store} do
    assert RecoveryProofStore.live_count(:openai, store) == 0
    assert RecoveryProofStore.live_count(:xai, store) == 0
    assert RecoveryProofStore.live_count(:unknown, store) == 0
  end

  defp future_deadline, do: System.monotonic_time(:millisecond) + 60_000

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before deadline")
      else
        Process.sleep(5)
        do_wait_until(fun, deadline)
      end
    end
  end
end
