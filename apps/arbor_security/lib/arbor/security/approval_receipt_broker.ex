defmodule Arbor.Security.ApprovalReceiptBroker do
  @moduledoc false

  use GenServer

  alias Arbor.Security.Config
  alias Arbor.Security.PrivateState
  alias Arbor.Security.SupervisedOwner

  @version 1
  @ttl_ms 30_000
  @max_entries 4_096
  @token_bytes 32
  @issuer_custody_bytes 32
  @test_mode Mix.env() == :test
  @domain "arbor.security.approval_receipt.v1\0"
  @issuer_custody_domain "arbor.security.approval_receipt.issuer-custody.v1\0"
  @owner_table :arbor_security_approval_receipt_broker_owner
  @confirmation_owner_table :arbor_trust_confirmation_tracker_owner
  @private_state_anchor {__MODULE__, :private_state}
  @private_state_schema :approval_receipt_broker_v1
  @receipt_keys MapSet.new([
                  :v,
                  :token,
                  :request_id,
                  :principal_id,
                  :resource_uri,
                  :action,
                  :argument_digest,
                  :expires_at_ms,
                  :signature
                ])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec issue(String.t(), String.t(), atom() | nil, String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def issue(principal_id, resource_uri, action, argument_digest, request_id) do
    safe_call({:issue, principal_id, resource_uri, action, argument_digest, request_id, nil})
  end

  @doc false
  @spec claim_issuer(keyword()) :: {:ok, binary()} | {:error, atom()}
  def claim_issuer(opts \\ [])

  def claim_issuer(opts) when is_list(opts) do
    test_isolated? = @test_mode and Keyword.get(opts, :test_isolated_owner, false) == true
    authenticated_safe_call({:claim_issuer, test_isolated?})
  rescue
    _ -> {:error, :unauthorized_approval_issuer}
  end

  def claim_issuer(_opts), do: {:error, :unauthorized_approval_issuer}

  @doc false
  @spec issue_authorized(String.t(), String.t(), atom() | nil, String.t(), String.t(), term()) ::
          {:ok, map()} | {:error, atom()}
  def issue_authorized(principal_id, resource_uri, action, argument_digest, request_id, custody) do
    safe_call({:issue, principal_id, resource_uri, action, argument_digest, request_id, custody})
  end

  if @test_mode do
    @doc false
    def issue_for_test(principal_id, resource_uri, action, argument_digest, request_id) do
      safe_call(
        {:issue_for_test, principal_id, resource_uri, action, argument_digest, request_id}
      )
    end
  end

  @spec verify(term(), String.t(), String.t(), atom() | nil, String.t()) ::
          :ok | {:error, :invalid_approval_receipt}
  def verify(receipt, principal_id, resource_uri, action, argument_digest) do
    safe_call({:verify, receipt, principal_id, resource_uri, action, argument_digest})
    |> normalize_verification()
  end

  @spec consume(term(), String.t(), String.t(), atom() | nil, String.t()) ::
          :ok | {:error, :invalid_approval_receipt}
  def consume(receipt, principal_id, resource_uri, action, argument_digest) do
    safe_call({:consume, receipt, principal_id, resource_uri, action, argument_digest})
    |> normalize_verification()
  end

  @spec confirm_security_consumed(term(), String.t(), String.t(), atom() | nil, String.t()) ::
          :ok | {:error, :invalid_approval_receipt}
  def confirm_security_consumed(receipt, principal_id, resource_uri, action, argument_digest) do
    safe_call({:confirm, receipt, principal_id, resource_uri, action, argument_digest})
    |> normalize_verification()
  end

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    with {:ok, issuer_owner} <- Config.approval_receipt_issuer_owner() do
      table = :ets.new(@owner_table, [:named_table, :protected, :set, read_concurrency: true])
      true = :ets.insert(table, {:owner_pid, self()})

      state = %{
        key: :crypto.strong_rand_bytes(32),
        entries: %{},
        issuer: nil,
        issuer_owner: issuer_owner,
        authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
        owner_table: table
      }

      {:ok, PrivateState.new(@private_state_anchor, @private_state_schema, state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(_request, _from, private_state),
    do: {:reply, {:error, :unauthorized_approval_issuer}, private_state}

  defp dispatch_authenticated_call({:claim_issuer, test_isolated?}, {issuer_pid, _tag}, state) do
    if authorize_issuer_claim(issuer_pid, test_isolated?, state.issuer_owner) do
      custody = :crypto.strong_rand_bytes(@issuer_custody_bytes)
      state = replace_issuer(state, issuer_pid, custody)
      {:reply, {:ok, custody}, state}
    else
      {:reply, {:error, :unauthorized_approval_issuer}, state}
    end
  end

  defp dispatch_authenticated_call(
         {:issue, principal_id, resource_uri, action, digest, request_id, custody},
         {issuer_pid, _tag},
         state
       ) do
    now = System.monotonic_time(:millisecond)
    entries = prune(state.entries, now)

    with :ok <- authorize_issuer(issuer_pid, custody, state),
         :ok <- validate_binding(principal_id, resource_uri, action, digest, request_id),
         true <- map_size(entries) < @max_entries,
         {:ok, receipt, entry} <-
           mint(state.key, principal_id, resource_uri, action, digest, request_id, now, entries) do
      {:reply, {:ok, receipt}, %{state | entries: Map.put(entries, receipt.token, entry)}}
    else
      false ->
        {:reply, {:error, :approval_receipt_capacity_exceeded}, %{state | entries: entries}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | entries: entries}}
    end
  end

  defp dispatch_authenticated_call(
         {:issue_for_test, principal_id, resource_uri, action, digest, request_id},
         _from,
         state
       ) do
    now = System.monotonic_time(:millisecond)
    entries = prune(state.entries, now)

    with true <- @test_mode,
         :ok <- validate_binding(principal_id, resource_uri, action, digest, request_id),
         true <- map_size(entries) < @max_entries,
         {:ok, receipt, entry} <-
           mint(state.key, principal_id, resource_uri, action, digest, request_id, now, entries) do
      {:reply, {:ok, receipt}, %{state | entries: Map.put(entries, receipt.token, entry)}}
    else
      false ->
        reason =
          if @test_mode,
            do: :approval_receipt_capacity_exceeded,
            else: :unauthorized_approval_issuer

        {:reply, {:error, reason}, %{state | entries: entries}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | entries: entries}}
    end
  end

  defp dispatch_authenticated_call(
         {operation, receipt, principal, resource, action, digest},
         _from,
         state
       )
       when operation in [:verify, :consume, :confirm] do
    now = System.monotonic_time(:millisecond)
    entries = prune(state.entries, now)

    case validate_receipt(
           state.key,
           entries,
           receipt,
           principal,
           resource,
           action,
           digest,
           operation,
           now
         ) do
      {:ok, token} when operation == :consume ->
        entry = Map.fetch!(entries, token)
        next = Map.put(entries, token, %{entry | status: :security_consumed})
        {:reply, :ok, %{state | entries: next}}

      {:ok, token} when operation == :confirm ->
        {:reply, :ok, %{state | entries: Map.delete(entries, token)}}

      {:ok, _token} ->
        {:reply, :ok, %{state | entries: entries}}

      {:error, _reason} ->
        {:reply, {:error, :invalid_approval_receipt}, %{state | entries: entries}}
    end
  end

  defp dispatch_authenticated_call(_request, _caller, state),
    do: {:reply, {:error, :unauthorized_approval_issuer}, state}

  defp handle_private_info(
         {:DOWN, ref, :process, pid, _reason},
         %{issuer: %{pid: pid, monitor: ref}} = state
       ) do
    {:noreply, %{state | issuer: nil}}
  end

  defp handle_private_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        {:reply, reply, next_state} =
          dispatch_authenticated_call(request, {caller, reply_to}, state)

        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, next_state}

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(message, private_state) do
    with {:ok, state} <- private_state(private_state) do
      case handle_private_info(message, state) do
        {:noreply, next_state} ->
          case put_private_state(private_state, next_state) do
            :ok -> {:noreply, private_state}
            {:error, _reason} -> {:stop, :invalid_private_state, private_state}
          end
      end
    else
      {:error, _reason} -> {:stop, :invalid_private_state, private_state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    count =
      case private_state(Map.get(status, :state, %{})) do
        {:ok, %{entries: entries}} -> map_size(entries)
        {:error, _reason} -> 0
      end

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, %{approval_receipt_count: count})
    |> redact(:reason)
    |> redact(:log)
  end

  @impl true
  def terminate(_reason, private_state) do
    case private_state(private_state) do
      {:ok, %{issuer: %{monitor: monitor}}} when is_reference(monitor) ->
        Process.demonitor(monitor, [:flush])

      _ ->
        :ok
    end

    PrivateState.delete(private_state, @private_state_anchor)
    :ok
  end

  defp private_state(state) do
    PrivateState.fetch(
      state,
      @private_state_anchor,
      @private_state_schema,
      &valid_private_state?/1
    )
  end

  defp put_private_state(handle, state) do
    PrivateState.replace(
      handle,
      @private_state_anchor,
      @private_state_schema,
      state,
      &valid_private_state?/1
    )
  end

  defp valid_private_state?(state) when is_map(state) do
    Map.keys(state) |> Enum.sort() ==
      [:authenticated_calls, :entries, :issuer, :issuer_owner, :key, :owner_table] and
      is_reference(state.authenticated_calls) and is_map(state.entries) and
      is_binary(state.key) and byte_size(state.key) == 32 and
      valid_issuer?(state.issuer) and is_map(state.issuer_owner) and
      (is_atom(state.owner_table) or is_reference(state.owner_table))
  end

  defp valid_private_state?(_state), do: false

  defp valid_issuer?(nil), do: true

  defp valid_issuer?(%{pid: pid, monitor: monitor, digest: digest}) do
    is_pid(pid) and is_reference(monitor) and is_binary(digest) and byte_size(digest) == 32
  end

  defp valid_issuer?(_issuer), do: false

  defp mint(key, principal, resource, action, digest, request_id, now, entries, attempts \\ 8)

  defp mint(_key, _principal, _resource, _action, _digest, _request, _now, _entries, 0),
    do: {:error, :approval_receipt_issue_failed}

  defp mint(key, principal, resource, action, digest, request_id, now, entries, attempts) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    if Map.has_key?(entries, token) do
      mint(key, principal, resource, action, digest, request_id, now, entries, attempts - 1)
    else
      unsigned = %{
        v: @version,
        token: token,
        request_id: request_id,
        principal_id: principal,
        resource_uri: resource,
        action: action,
        argument_digest: digest,
        expires_at_ms: now + @ttl_ms
      }

      signature = sign(key, unsigned)
      receipt = Map.put(unsigned, :signature, signature)
      {:ok, receipt, %{receipt: receipt, status: :issued, expires_at_ms: unsigned.expires_at_ms}}
    end
  end

  defp validate_receipt(
         key,
         entries,
         receipt,
         principal,
         resource,
         action,
         digest,
         operation,
         now
       )
       when is_map(receipt) and not is_struct(receipt) do
    with true <- MapSet.new(Map.keys(receipt)) == @receipt_keys,
         %{token: token, expires_at_ms: expires_at, signature: signature} <- receipt,
         true <- is_binary(token) and byte_size(token) == 43,
         true <- is_integer(expires_at) and expires_at > now,
         true <- receipt.v == @version,
         true <- receipt.principal_id == principal,
         true <- receipt.resource_uri == resource,
         true <- receipt.action == action,
         true <- receipt.argument_digest == digest,
         true <- secure_equal?(signature, sign(key, Map.delete(receipt, :signature))),
         %{receipt: stored, status: status, expires_at_ms: ^expires_at} <- Map.get(entries, token),
         true <- stored == receipt,
         true <- valid_status?(operation, status) do
      {:ok, token}
    else
      _ -> {:error, :invalid_approval_receipt}
    end
  end

  defp validate_receipt(_, _, _, _, _, _, _, _, _),
    do: {:error, :invalid_approval_receipt}

  defp valid_status?(:verify, :issued), do: true
  defp valid_status?(:consume, :issued), do: true
  defp valid_status?(:confirm, :security_consumed), do: true
  defp valid_status?(_, _), do: false

  defp validate_binding(principal, resource, action, digest, request_id) do
    if is_binary(principal) and principal != "" and is_binary(resource) and
         Arbor.Contracts.Security.CapabilityUri.valid?(resource) and
         (is_atom(action) or is_nil(action)) and valid_digest?(digest) and
         is_binary(request_id) and byte_size(request_id) in 1..256,
       do: :ok,
       else: {:error, :invalid_approval_receipt_binding}
  end

  # Receipt minting is confined to the exact supervised Trust owner that
  # claimed a broker-lifetime credential. The raw credential remains in that
  # process's private ETS custody; this broker retains only its digest.
  defp authorize_issuer(issuer_pid, custody, %{issuer: issuer})
       when is_pid(issuer_pid) and is_binary(custody) and
              byte_size(custody) == @issuer_custody_bytes do
    case issuer do
      %{pid: ^issuer_pid, digest: expected} when is_binary(expected) ->
        if Process.alive?(issuer_pid) and
             :crypto.hash_equals(expected, issuer_custody_digest(custody)),
           do: :ok,
           else: {:error, :unauthorized_approval_issuer}

      _ ->
        {:error, :unauthorized_approval_issuer}
    end
  end

  defp authorize_issuer(_issuer_pid, _custody, _state),
    do: {:error, :unauthorized_approval_issuer}

  defp authorize_issuer_claim(issuer_pid, test_isolated?, owner) when is_pid(issuer_pid) do
    owns_directory? =
      case :ets.lookup(@confirmation_owner_table, :owner_pid) do
        [{:owner_pid, ^issuer_pid}] -> :ets.info(@confirmation_owner_table, :owner) == issuer_pid
        _ -> false
      end

    owns_directory? and Process.whereis(owner.registered_name) == issuer_pid and
      (SupervisedOwner.authorized?(issuer_pid, owner.application, owner.path) or
         (@test_mode and test_isolated?))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp authorize_issuer_claim(_issuer_pid, _test_isolated?, _owner), do: false

  defp replace_issuer(%{issuer: %{monitor: old_ref}} = state, issuer_pid, custody) do
    Process.demonitor(old_ref, [:flush])
    put_issuer(state, issuer_pid, custody)
  end

  defp replace_issuer(state, issuer_pid, custody), do: put_issuer(state, issuer_pid, custody)

  defp put_issuer(state, issuer_pid, custody) do
    issuer = %{
      pid: issuer_pid,
      monitor: Process.monitor(issuer_pid),
      digest: issuer_custody_digest(custody)
    }

    %{state | issuer: issuer}
  end

  defp issuer_custody_digest(custody),
    do: :crypto.hash(:sha256, [@issuer_custody_domain, custody])

  defp valid_digest?(digest) when is_binary(digest),
    do: byte_size(digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_digest?(_), do: false

  defp sign(key, unsigned) do
    bytes = @domain <> :erlang.term_to_binary(unsigned, [:deterministic])
    :crypto.mac(:hmac, :sha256, key, bytes) |> Base.url_encode64(padding: false)
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_, _), do: false

  defp prune(entries, now) do
    Map.reject(entries, fn {_token, entry} -> entry.expires_at_ms <= now end)
  end

  defp safe_call(message) do
    case broker_pid() do
      pid when is_pid(pid) -> Arbor.Common.authenticated_call(pid, message)
      _ -> {:error, :invalid_approval_receipt}
    end
  catch
    :exit, _ -> {:error, :invalid_approval_receipt}
  end

  defp authenticated_safe_call(message) do
    case broker_pid() do
      pid when is_pid(pid) -> Arbor.Common.authenticated_call(pid, message)
      _ -> {:error, :invalid_approval_receipt}
    end
  catch
    :exit, _ -> {:error, :invalid_approval_receipt}
  end

  defp broker_pid,
    do:
      SupervisedOwner.protected_directory_owner(
        @owner_table,
        :owner_pid,
        :arbor_security,
        [__MODULE__]
      )

  defp normalize_verification(:ok), do: :ok
  defp normalize_verification(_), do: {:error, :invalid_approval_receipt}

  defp redact(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end
