defmodule Arbor.Security.MasterKeyAccessOwner do
  @moduledoc false

  use GenServer

  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.PrivateState
  alias Arbor.Security.SupervisedOwner

  @name __MODULE__
  @directory :arbor_security_master_key_access_owner_directory
  @private_state_anchor {__MODULE__, :private_state}
  @private_state_schema :master_key_access_owner_v1
  @type purpose :: :authority_record | :capability_revocation_ledger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @spec authenticate(reference(), purpose(), binary()) :: {:ok, binary()} | {:error, atom()}
  def authenticate(token, purpose, bytes)
      when is_reference(token) and is_binary(bytes) do
    call({:authenticate, token, purpose, bytes})
  end

  def authenticate(_token, _purpose, _bytes), do: {:error, :master_key_access_unauthorized}

  @doc false
  def authenticate_from_supervisor(supervisor, token, purpose, bytes)
      when is_pid(supervisor) and is_reference(token) and is_binary(bytes) do
    direct_call(supervisor, {:authenticate_from_supervisor, supervisor, token, purpose, bytes})
  end

  def authenticate_from_supervisor(_supervisor, _token, _purpose, _bytes),
    do: {:error, :master_key_access_unauthorized}

  @spec verify(reference(), purpose(), binary(), binary()) :: :ok | {:error, atom()}
  def verify(token, purpose, bytes, expected)
      when is_reference(token) and is_binary(bytes) and is_binary(expected) do
    call({:verify, token, purpose, bytes, expected})
  end

  def verify(_token, _purpose, _bytes, _expected),
    do: {:error, :master_key_access_unauthorized}

  @doc false
  def verify_from_supervisor(supervisor, token, purpose, bytes, expected)
      when is_pid(supervisor) and is_reference(token) and is_binary(bytes) and
             is_binary(expected) do
    direct_call(
      supervisor,
      {:verify_from_supervisor, supervisor, token, purpose, bytes, expected}
    )
  end

  def verify_from_supervisor(_supervisor, _token, _purpose, _bytes, _expected),
    do: {:error, :master_key_access_unauthorized}

  @doc false
  def owner_process? do
    match?({:ok, owner} when owner == self(), owner_pid())
  end

  @doc false
  def owner_process_from_supervisor?(supervisor) when is_pid(supervisor),
    do: SupervisedOwner.child_pid(supervisor, __MODULE__) == self()

  def owner_process_from_supervisor?(_supervisor), do: false

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    with {:ok, supervisor_pid} <- startup_supervisor_pid(),
         :ok <- claim_directory(),
         {:ok, grants} <- build_grants(Keyword.get(opts, :store_tokens)) do
      state = %{
        grants: grants,
        security_supervisor_pid: supervisor_pid,
        authenticated_calls: Arbor.Common.new_authenticated_call_custody()
      }

      {:ok, PrivateState.new(@private_state_anchor, @private_state_schema, state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(_request, _from, private_state),
    do: {:reply, {:error, :master_key_access_unauthorized}, private_state}

  defp handle_authenticated_request({:authenticate, token, purpose, bytes}, caller, state) do
    case authorize_and_bind(state.grants, token, purpose, caller) do
      {:ok, grants} ->
        {:reply, SigningKeyStore.authenticate_with_master(purpose, bytes),
         %{state | grants: grants}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request({:verify, token, purpose, bytes, expected}, caller, state) do
    case authorize_and_bind(state.grants, token, purpose, caller) do
      {:ok, grants} ->
        {:reply, SigningKeyStore.verify_with_master(purpose, bytes, expected),
         %{state | grants: grants}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(
         {:authenticate_from_supervisor, supervisor, token, purpose, bytes},
         caller,
         %{security_supervisor_pid: supervisor} = state
       ) do
    case authorize_and_bind(state.grants, token, purpose, caller, supervisor) do
      {:ok, grants} ->
        {:reply,
         SigningKeyStore.authenticate_with_master_from_supervisor(supervisor, purpose, bytes),
         %{state | grants: grants}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(
         {:verify_from_supervisor, supervisor, token, purpose, bytes, expected},
         caller,
         %{security_supervisor_pid: supervisor} = state
       ) do
    case authorize_and_bind(state.grants, token, purpose, caller, supervisor) do
      {:ok, grants} ->
        {:reply,
         SigningKeyStore.verify_with_master_from_supervisor(
           supervisor,
           purpose,
           bytes,
           expected
         ), %{state | grants: grants}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(_request, _caller, state),
    do: {:reply, {:error, :master_key_access_unauthorized}, state}

  @impl true
  def handle_info(message, private_state) do
    with {:ok, state} <- private_state(private_state) do
      case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
        {:authenticated, caller, request, reply_to} ->
          {:reply, reply, next_state} = handle_authenticated_request(request, caller, state)

          case put_private_state(private_state, next_state) do
            :ok ->
              :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
              {:noreply, private_state}

            {:error, _reason} ->
              :ok =
                Arbor.Common.reply_authenticated_call(
                  reply_to,
                  {:error, :master_key_access_unauthorized}
                )

              {:stop, :invalid_private_state, private_state}
          end

        result when result in [:pending, :expired, :rejected, :unrecognized] ->
          {:noreply, private_state}
      end
    else
      {:error, _reason} -> {:stop, :invalid_private_state, private_state}
    end
  end

  @impl true
  def format_status(status) when is_map(status), do: Map.put(status, :state, :redacted)

  @impl true
  def terminate(_reason, private_state) do
    PrivateState.delete(private_state, @private_state_anchor)
    :ok
  end

  defp call(request) do
    with {:ok, owner} <- owner_pid() do
      Arbor.Common.authenticated_call(owner, request, 30_000)
    end
  rescue
    _ -> {:error, :master_key_access_unavailable}
  catch
    :exit, _ -> {:error, :master_key_access_unavailable}
  end

  defp direct_call(supervisor, request) do
    case SupervisedOwner.child_pid(supervisor, __MODULE__) do
      owner when is_pid(owner) -> Arbor.Common.authenticated_call(owner, request, 30_000)
      nil -> {:error, :master_key_access_unavailable}
    end
  rescue
    _ -> {:error, :master_key_access_unavailable}
  catch
    :exit, _ -> {:error, :master_key_access_unavailable}
  end

  defp build_grants(store_tokens) when is_map(store_tokens) and map_size(store_tokens) > 0 do
    Enum.reduce_while(store_tokens, {:ok, %{}}, fn
      {store_name, token}, {:ok, grants}
      when is_atom(store_name) and is_reference(token) ->
        purposes =
          if store_name == :arbor_security_capabilities,
            do: MapSet.new([:authority_record, :capability_revocation_ledger]),
            else: MapSet.new([:authority_record])

        grant = %{pid: nil, purposes: purposes, store_name: store_name}
        {:cont, {:ok, Map.put(grants, token, grant)}}

      _invalid, _acc ->
        {:halt, {:error, :invalid_master_key_access_configuration}}
    end)
  end

  defp build_grants(_store_tokens), do: {:error, :invalid_master_key_access_configuration}

  defp authorize_and_bind(grants, token, purpose, caller, supervisor \\ nil) do
    case Map.fetch(grants, token) do
      {:ok, %{pid: nil, purposes: purposes, store_name: store_name} = grant} ->
        if legitimate_store?(caller, store_name, supervisor) and
             MapSet.member?(purposes, purpose),
           do: {:ok, Map.put(grants, token, %{grant | pid: caller})},
           else: {:error, :master_key_access_unauthorized}

      {:ok, %{pid: bound, purposes: purposes, store_name: store_name} = grant} ->
        cond do
          bound == caller and legitimate_store?(caller, store_name, supervisor) and
              MapSet.member?(purposes, purpose) ->
            {:ok, grants}

          not Process.alive?(bound) and legitimate_store?(caller, store_name, supervisor) and
              MapSet.member?(purposes, purpose) ->
            {:ok, Map.put(grants, token, %{grant | pid: caller})}

          true ->
            {:error, :master_key_access_unauthorized}
        end

      :error ->
        {:error, :master_key_access_unauthorized}
    end
  end

  defp legitimate_store?(caller, store_name, nil) when is_pid(caller) and is_atom(store_name) do
    Process.whereis(store_name) == caller and
      SupervisedOwner.authorized?(caller, :arbor_security, [store_name])
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp legitimate_store?(caller, store_name, supervisor)
       when is_pid(caller) and is_atom(store_name) and is_pid(supervisor) do
    Process.whereis(store_name) == caller and
      SupervisedOwner.child_pid(supervisor, store_name) == caller
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp legitimate_store?(_caller, _store_name, _supervisor), do: false

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
      [:authenticated_calls, :grants, :security_supervisor_pid] and
      is_reference(state.authenticated_calls) and is_map(state.grants) and
      is_pid(state.security_supervisor_pid) and
      Enum.all?(state.grants, fn
        {token, %{pid: pid, purposes: %MapSet{} = purposes, store_name: store_name}} ->
          is_reference(token) and (is_nil(pid) or is_pid(pid)) and is_atom(store_name) and
            not is_nil(store_name) and MapSet.size(purposes) > 0

        _ ->
          false
      end)
  end

  defp valid_private_state?(_state), do: false

  defp startup_supervisor_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> linked_supervisor(pid)
      [name | _] when is_atom(name) -> name |> Process.whereis() |> linked_supervisor()
      _other -> {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(pid) when is_pid(pid) do
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if pid in links, do: {:ok, pid}, else: {:error, :security_supervisor_unavailable}

      _other ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(_pid), do: {:error, :security_supervisor_unavailable}

  defp claim_directory do
    table = :ets.new(@directory, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :master_key_access_owner_directory_unavailable}
  end

  defp owner_pid do
    case SupervisedOwner.protected_directory_owner(
           @directory,
           :owner,
           :arbor_security,
           [__MODULE__]
         ) do
      owner when is_pid(owner) -> {:ok, owner}
      nil -> {:error, :master_key_access_unavailable}
    end
  end
end
