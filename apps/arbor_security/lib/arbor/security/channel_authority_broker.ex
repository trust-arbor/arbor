defmodule Arbor.Security.ChannelAuthority do
  @moduledoc false

  @enforce_keys [:token, :principal_id, :operation]
  defstruct [:token, :principal_id, :operation]

  @type operation :: :send | :read
  @type t :: %__MODULE__{
          token: binary(),
          principal_id: String.t(),
          operation: operation()
        }

  @spec canonicalize(term()) :: {:ok, t()} | {:error, :invalid_channel_authority}
  def canonicalize(%__MODULE__{} = authority) do
    token = Map.get(authority, :token)
    principal_id = Map.get(authority, :principal_id)
    operation = Map.get(authority, :operation)

    if is_binary(token) and byte_size(token) == 32 and is_binary(principal_id) and
         principal_id != "" and operation in [:send, :read] do
      {:ok, %__MODULE__{token: token, principal_id: principal_id, operation: operation}}
    else
      {:error, :invalid_channel_authority}
    end
  end

  def canonicalize(_authority), do: {:error, :invalid_channel_authority}
end

defimpl Inspect, for: Arbor.Security.ChannelAuthority do
  def inspect(authority, opts) do
    details =
      Inspect.Algebra.concat([
        "principal_id: ",
        Inspect.Algebra.to_doc(Map.get(authority, :principal_id), opts),
        ", operation: ",
        Inspect.Algebra.to_doc(Map.get(authority, :operation), opts),
        ", token: [REDACTED]"
      ])

    Inspect.Algebra.concat(["#Arbor.Security.ChannelAuthority<", details, ">"])
  end
end

defmodule Arbor.Security.ChannelAuthorityBroker do
  @moduledoc """
  Supervised authority boundary for authenticated channel signing and direct-message crypto.

  The broker exchanges a live agent signing authority for an operation-specific,
  caller-bound channel authority. Channel actions receive only that narrow
  authority. Raw signing and X25519 private keys remain inside `arbor_security`.
  """

  use GenServer

  alias Arbor.Security.ChannelAuthority
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Keychain
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SupervisedOwner

  @signature_domain "arbor.channel.message.v1"
  @allowed_signing_purposes [:session, :heartbeat, :action_cycle]
  @max_channel_id_bytes 512
  @max_content_bytes 8 * 1_024 * 1_024
  @call_timeout 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec issue(term(), ChannelAuthority.operation()) ::
          {:ok, ChannelAuthority.t()} | {:error, term()}
  def issue(signing_authority, operation) when operation in [:send, :read] do
    call({:issue, signing_authority, operation})
  end

  def issue(_signing_authority, _operation), do: {:error, :invalid_channel_operation}

  @spec close(term()) :: :ok | {:error, term()}
  def close(channel_authority), do: call({:close, channel_authority})

  @spec principal(term(), ChannelAuthority.operation()) ::
          {:ok, String.t()} | {:error, term()}
  def principal(channel_authority, operation) when operation in [:send, :read] do
    call({:principal, channel_authority, operation})
  end

  def principal(_channel_authority, _operation),
    do: {:error, :channel_authority_unauthorized}

  @spec sign(term(), String.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def sign(channel_authority, channel_id, content)
      when is_binary(channel_id) and is_binary(content) do
    call({:sign, channel_authority, channel_id, content})
  end

  def sign(_channel_authority, _channel_id, _content),
    do: {:error, :channel_authority_unauthorized}

  @spec seal(term(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def seal(channel_authority, peer_id, plaintext)
      when is_binary(peer_id) and is_binary(plaintext) do
    call({:seal, channel_authority, peer_id, plaintext})
  end

  def seal(_channel_authority, _peer_id, _plaintext),
    do: {:error, :channel_authority_unauthorized}

  @spec unseal(term(), String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def unseal(channel_authority, sender_id, sealed)
      when is_binary(sender_id) and is_map(sealed) do
    call({:unseal, channel_authority, sender_id, sealed})
  end

  def unseal(_channel_authority, _sender_id, _sealed),
    do: {:error, :channel_authority_unauthorized}

  @spec verify(String.t(), String.t(), binary(), binary()) :: boolean() | nil
  def verify(sender_id, channel_id, content, signature)
      when is_binary(sender_id) and is_binary(channel_id) and is_binary(content) and
             is_binary(signature) do
    with {:ok, payload} <- signature_payload(channel_id, sender_id, content),
         {:ok, public_key} <- Registry.lookup(sender_id) do
      Crypto.verify(payload, signature, public_key)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def verify(_sender_id, _channel_id, _content, _signature), do: false

  @doc false
  @spec signature_payload(String.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, :invalid_channel_message}
  def signature_payload(channel_id, sender_id, content)
      when is_binary(channel_id) and is_binary(sender_id) and is_binary(content) do
    if channel_id != "" and byte_size(channel_id) <= @max_channel_id_bytes and
         sender_id != "" and byte_size(sender_id) <= @max_channel_id_bytes and
         byte_size(content) <= @max_content_bytes do
      {:ok,
       length_prefix(@signature_domain) <>
         length_prefix(channel_id) <>
         length_prefix(sender_id) <>
         <<byte_size(content)::64-big-unsigned-integer>> <> content}
    else
      {:error, :invalid_channel_message}
    end
  end

  def signature_payload(_channel_id, _sender_id, _content),
    do: {:error, :invalid_channel_message}

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    {:ok,
     %{
       authorities: %{},
       monitors: %{},
       authenticated_calls: Arbor.Common.new_authenticated_call_custody()
     }}
  end

  @impl true
  def handle_call(_request, _from, state),
    do: {:reply, {:error, :channel_authority_unauthorized}, state}

  defp handle_authenticated_call({:issue, signing_authority, operation}, caller, state)
       when operation in [:send, :read] do
    reply =
      with {:ok, %{principal_id: principal_id, purpose: purpose, owner_pid: source_owner}} <-
             SigningAuthorityBroker.channel_identity(signing_authority),
           true <- purpose in @allowed_signing_purposes,
           true <- caller == source_owner,
           true <- Process.alive?(caller),
           true <- Process.alive?(source_owner) do
        token = :crypto.strong_rand_bytes(32)
        owner_monitor = Process.monitor(caller)
        source_secret = make_ref()
        broker = self()

        {source_pid, source_monitor} =
          spawn_monitor(fn ->
            source_lease_loop(
              signing_authority,
              broker,
              source_owner,
              source_secret,
              principal_id,
              purpose
            )
          end)

        authority = %ChannelAuthority{
          token: token,
          principal_id: principal_id,
          operation: operation
        }

        entry = %{
          authority: authority,
          owner: caller,
          owner_monitor: owner_monitor,
          source_pid: source_pid,
          source_monitor: source_monitor,
          source_secret: source_secret
        }

        {:ok, authority, entry}
      else
        _ -> {:error, :channel_authority_unauthorized}
      end

    case reply do
      {:ok, authority, entry} ->
        next = %{
          state
          | authorities: Map.put(state.authorities, authority.token, entry),
            monitors:
              state.monitors
              |> Map.put(entry.owner_monitor, authority.token)
              |> Map.put(entry.source_monitor, authority.token)
        }

        {:reply, {:ok, authority}, next}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp handle_authenticated_call({:principal, authority, operation}, caller, state) do
    reply =
      with {:ok, entry} <- authorize(authority, operation, caller, state) do
        {:ok, entry.authority.principal_id}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:sign, authority, channel_id, content}, caller, state) do
    reply =
      with {:ok, entry} <- authorize(authority, :send, caller, state),
           {:ok, payload} <-
             signature_payload(channel_id, entry.authority.principal_id, content),
           {:ok, private_key} <- signing_private_key(entry.authority.principal_id) do
        {:ok, Crypto.sign(payload, private_key)}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:seal, authority, peer_id, plaintext}, caller, state) do
    reply =
      with {:ok, entry} <- authorize(authority, :send, caller, state),
           {:ok, sender_keychain} <- keychain(entry.authority.principal_id),
           {:ok, peer_signing_public} <- Registry.lookup(peer_id),
           {:ok, peer_encryption_public} <- Registry.lookup_encryption_key(peer_id),
           sender_keychain =
             Keychain.add_peer(
               sender_keychain,
               peer_id,
               peer_signing_public,
               peer_encryption_public
             ) do
        normalize_seal_result(Keychain.seal_for_peer(sender_keychain, peer_id, plaintext))
      else
        {:error, _reason} = error -> error
        _ -> {:error, :channel_encryption_unavailable}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:unseal, authority, sender_id, sealed}, caller, state) do
    reply =
      with {:ok, entry} <- authorize(authority, :read, caller, state),
           {:ok, reader_keychain} <- keychain(entry.authority.principal_id),
           {:ok, sender_signing_public} <- Registry.lookup(sender_id),
           {:ok, sender_encryption_public} <- Registry.lookup_encryption_key(sender_id),
           reader_keychain =
             Keychain.add_peer(
               reader_keychain,
               sender_id,
               sender_signing_public,
               sender_encryption_public
             ) do
        normalize_unseal_result(Keychain.unseal_from_peer(reader_keychain, sender_id, sealed))
      else
        {:error, _reason} = error -> error
        _ -> {:error, :channel_decryption_unavailable}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:close, authority}, caller, state) do
    case ChannelAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        case Map.get(state.authorities, canonical.token) do
          %{owner: ^caller, authority: ^canonical} = entry ->
            {:reply, :ok, drop_entry(state, canonical.token, entry)}

          _ ->
            {:reply, {:error, :channel_authority_unauthorized}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :channel_authority_unauthorized}, state}
    end
  end

  defp handle_authenticated_call(_request, _caller, state),
    do: {:reply, {:error, :channel_authority_unauthorized}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {token, _monitors} ->
        case Map.get(state.authorities, token) do
          nil -> {:noreply, state}
          entry -> {:noreply, drop_entry(state, token, entry)}
        end
    end
  end

  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        case handle_authenticated_call(request, caller, state) do
          {:reply, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:noreply, next_state}
        end

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    count =
      case get_in(status, [:state, :authorities]) do
        authorities when is_map(authorities) -> map_size(authorities)
        _ -> 0
      end

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, %{authority_count: count})
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
  end

  defp authorize(authority, operation, caller, state) do
    with {:ok, canonical} <- ChannelAuthority.canonicalize(authority),
         ^operation <- canonical.operation,
         %{authority: ^canonical, owner: ^caller} = entry <-
           Map.get(state.authorities, canonical.token),
         true <- Process.alive?(caller),
         true <- Process.alive?(entry.source_pid),
         :ok <- validate_source_lease(entry) do
      {:ok, entry}
    else
      _ -> {:error, :channel_authority_unauthorized}
    end
  end

  defp keychain(principal_id) do
    with {:ok, %{signing: signing_private, encryption: encryption_private} = keypair} <-
           load_keypair(principal_id),
         {signing_public, _expanded_signing_private} <-
           :crypto.generate_key(:eddsa, :ed25519, signing_private),
         {encryption_public, _expanded_encryption_private} <-
           :crypto.generate_key(:ecdh, :x25519, encryption_private),
         {:ok, ^signing_public} <- Registry.lookup(principal_id),
         {:ok, ^encryption_public} <- Registry.lookup_encryption_key(principal_id) do
      {:ok,
       Keychain.from_keypairs(
         principal_id,
         {signing_public, keypair.signing},
         {encryption_public, keypair.encryption}
       )}
    else
      _ -> {:error, :channel_key_material_unavailable}
    end
  rescue
    _ -> {:error, :channel_key_material_unavailable}
  catch
    _, _ -> {:error, :channel_key_material_unavailable}
  end

  defp load_keypair(principal_id) do
    case SigningKeyStore.get_keypair(principal_id) do
      {:ok, %{signing: signing, encryption: encryption} = keypair}
      when is_binary(signing) and is_binary(encryption) ->
        {:ok, keypair}

      _ ->
        {:error, :channel_key_material_unavailable}
    end
  end

  defp signing_private_key(principal_id) do
    with {:ok, %{signing: signing_private}} <- SigningKeyStore.get_keypair(principal_id),
         true <- is_binary(signing_private),
         {signing_public, _expanded_private} <-
           :crypto.generate_key(:eddsa, :ed25519, signing_private),
         {:ok, ^signing_public} <- Registry.lookup(principal_id) do
      {:ok, signing_private}
    else
      _ -> {:error, :channel_key_material_unavailable}
    end
  rescue
    _ -> {:error, :channel_key_material_unavailable}
  catch
    _, _ -> {:error, :channel_key_material_unavailable}
  end

  defp normalize_seal_result({:ok, sealed, _updated_keychain}), do: {:ok, sealed}
  defp normalize_seal_result({:ok, sealed}), do: {:ok, sealed}
  defp normalize_seal_result({:error, _reason}), do: {:error, :channel_encryption_failed}
  defp normalize_seal_result(_other), do: {:error, :channel_encryption_failed}

  defp normalize_unseal_result({:ok, plaintext, _updated_keychain}), do: {:ok, plaintext}
  defp normalize_unseal_result({:ok, plaintext}), do: {:ok, plaintext}
  defp normalize_unseal_result({:error, _reason}), do: {:error, :channel_decryption_failed}
  defp normalize_unseal_result(_other), do: {:error, :channel_decryption_failed}

  defp validate_source_lease(entry) do
    call_ref = make_ref()

    send(
      entry.source_pid,
      {:validate, self(), call_ref, entry.source_secret}
    )

    receive do
      {:channel_source_validation, source_pid, ^call_ref, :ok}
      when source_pid == entry.source_pid ->
        :ok

      {:channel_source_validation, source_pid, ^call_ref, {:error, _reason}}
      when source_pid == entry.source_pid ->
        {:error, :channel_authority_unauthorized}

      {:DOWN, monitor, :process, source_pid, _reason}
      when monitor == entry.source_monitor and source_pid == entry.source_pid ->
        {:error, :channel_authority_unauthorized}
    after
      @call_timeout -> {:error, :channel_authority_unauthorized}
    end
  end

  defp source_lease_loop(
         signing_authority,
         broker,
         source_owner,
         secret,
         principal_id,
         purpose
       ) do
    broker_monitor = Process.monitor(broker)
    source_owner_monitor = Process.monitor(source_owner)

    receive_source_lease(
      signing_authority,
      broker,
      secret,
      principal_id,
      purpose,
      broker_monitor,
      source_owner_monitor
    )
  end

  defp receive_source_lease(
         signing_authority,
         broker,
         secret,
         principal_id,
         purpose,
         broker_monitor,
         source_owner_monitor
       ) do
    receive do
      {:validate, ^broker, call_ref, ^secret} when is_reference(call_ref) ->
        result =
          case SigningAuthorityBroker.channel_identity(signing_authority) do
            {:ok, %{principal_id: ^principal_id, purpose: ^purpose}} -> :ok
            _ -> {:error, :channel_authority_unauthorized}
          end

        send(broker, {:channel_source_validation, self(), call_ref, result})

        receive_source_lease(
          signing_authority,
          broker,
          secret,
          principal_id,
          purpose,
          broker_monitor,
          source_owner_monitor
        )

      {:close, ^broker, ^secret} ->
        :ok

      {:DOWN, ^broker_monitor, :process, ^broker, _reason} ->
        :ok

      {:DOWN, ^source_owner_monitor, :process, _source_owner, _reason} ->
        :ok

      _other ->
        receive_source_lease(
          signing_authority,
          broker,
          secret,
          principal_id,
          purpose,
          broker_monitor,
          source_owner_monitor
        )
    end
  end

  defp drop_entry(state, token, entry) do
    send(entry.source_pid, {:close, self(), entry.source_secret})
    Process.demonitor(entry.owner_monitor, [:flush])
    Process.demonitor(entry.source_monitor, [:flush])

    %{
      state
      | authorities: Map.delete(state.authorities, token),
        monitors:
          state.monitors
          |> Map.delete(entry.owner_monitor)
          |> Map.delete(entry.source_monitor)
    }
  end

  defp length_prefix(value), do: <<byte_size(value)::32-big-unsigned-integer, value::binary>>

  defp call(message) do
    case SupervisedOwner.registered_child(
           __MODULE__,
           :arbor_security,
           [__MODULE__]
         ) do
      pid when is_pid(pid) -> Arbor.Common.authenticated_call(pid, message, @call_timeout)
      _ -> {:error, :channel_authority_unavailable}
    end
  rescue
    _ -> {:error, :channel_authority_unavailable}
  catch
    :exit, _ -> {:error, :channel_authority_unavailable}
  end
end
