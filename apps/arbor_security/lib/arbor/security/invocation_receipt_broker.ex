defmodule Arbor.Security.InvocationReceiptBroker do
  @moduledoc false

  use GenServer

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.InvocationReceipt
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.ReceiptIssuanceProof
  alias Arbor.Security.SupervisedOwner
  alias Arbor.Security.SystemAuthority

  @max_principal_bytes 256
  @max_resource_bytes 2_048

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec issue(Capability.t(), String.t(), String.t(), atom() | nil) ::
          {:ok, InvocationReceipt.t()} | {:error, atom()}
  def issue(%Capability{}, _principal_id, _resource_uri, _action) do
    {:error, :receipt_issuance_unauthorized}
  end

  def issue(_capability, _principal_id, _resource_uri, _action),
    do: {:error, :invalid_invocation_receipt}

  @doc false
  @spec issue_authorized(function()) ::
          {:ok, InvocationReceipt.t()} | {:error, atom()}
  def issue_authorized(proof) when is_function(proof, 1) do
    case SupervisedOwner.registered_child(__MODULE__, :arbor_security, [__MODULE__]) do
      pid when is_pid(pid) -> Arbor.Common.authenticated_call(pid, {:issue_authorized, proof})
      _ -> {:error, :receipt_signing_unavailable}
    end
  catch
    :exit, _ -> {:error, :receipt_signing_unavailable}
  end

  def issue_authorized(_proof), do: {:error, :receipt_issuance_unauthorized}

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    case startup_supervisor_pid() do
      {:ok, supervisor_pid} ->
        {:ok,
         %{
           security_supervisor_pid: supervisor_pid,
           authenticated_calls: Arbor.Common.new_authenticated_call_custody()
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(_request, _from, state),
    do: {:reply, {:error, :receipt_issuance_unauthorized}, state}

  defp handle_authenticated_request({:issue_authorized, proof}, caller, state) do
    result =
      with {:ok,
            %{
              capability: %Capability{} = submitted,
              principal_id: principal_id,
              resource_uri: resource_uri,
              action: action
            } = payload} <- ReceiptIssuanceProof.admit(proof, caller, :invocation),
           true <- map_size(payload) == 4,
           :ok <- validate_request(principal_id, resource_uri, action),
           {:ok, authoritative} <- capability_store_get(state, submitted.id),
           true <- authoritative == submitted,
           true <- authoritative.principal_id == principal_id,
           true <- Capability.valid?(authoritative),
           true <- Capability.grants_access?(authoritative, resource_uri),
           {:ok, :active} <- registry_identity_status(state, principal_id),
           :ok <- verify_capability_signature(state, authoritative),
           :ok <- Signer.verify_delegation_chain(authoritative, &registry_lookup(state, &1)),
           {:ok, receipt} <-
             InvocationReceipt.new(
               capability_id: authoritative.id,
               principal_id: principal_id,
               resource_uri: resource_uri,
               action: action,
               result: :granted,
               delegation_chain: authoritative.delegation_chain,
               session_id: authoritative.session_id,
               task_id: authoritative.task_id
             ) do
        sign_receipt(state, receipt)
      else
        _ -> {:error, :invalid_invocation_receipt}
      end

    {:reply, result, state}
  rescue
    _ -> {:reply, {:error, :invalid_invocation_receipt}, state}
  catch
    _, _ -> {:reply, {:error, :invalid_invocation_receipt}, state}
  end

  defp handle_authenticated_request(
         {:issue, _submitted, _principal_id, _resource_uri, _action},
         _caller,
         state
       ),
       do: {:reply, {:error, :receipt_issuance_unauthorized}, state}

  defp handle_authenticated_request(_request, _caller, state),
    do: {:reply, {:error, :receipt_issuance_unauthorized}, state}

  @impl true
  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        case handle_authenticated_request(request, caller, state) do
          {:reply, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:noreply, next_state}
        end

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
  end

  defp startup_supervisor_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) ->
        linked_supervisor(pid)

      [name | _] when is_atom(name) ->
        name
        |> Process.whereis()
        |> linked_supervisor()

      _ ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(pid) when is_pid(pid) do
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if pid in links,
          do: {:ok, pid},
          else: {:error, :security_supervisor_unavailable}

      _other ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(_pid), do: {:error, :security_supervisor_unavailable}

  defp validate_request(principal_id, resource_uri, action)
       when is_binary(principal_id) and is_binary(resource_uri) and
              (is_atom(action) or is_nil(action)) do
    if byte_size(principal_id) in 1..@max_principal_bytes and String.valid?(principal_id) and
         byte_size(resource_uri) in 1..@max_resource_bytes and String.valid?(resource_uri) and
         Arbor.Contracts.Security.CapabilityUri.valid?(resource_uri),
       do: :ok,
       else: {:error, :invalid_invocation_receipt}
  end

  defp validate_request(_principal_id, _resource_uri, _action),
    do: {:error, :invalid_invocation_receipt}

  defp supervised_registered_child_pid(state, child_id, registered_name) do
    with supervisor when is_pid(supervisor) <- Map.get(state, :security_supervisor_pid),
         true <- Process.alive?(supervisor),
         {^child_id, child_pid, _type, _modules} when is_pid(child_pid) <-
           Enum.find(Supervisor.which_children(supervisor), fn
             {id, _pid, _type, _modules} -> id == child_id
             _ -> false
           end),
         true <- Process.whereis(registered_name) == child_pid do
      child_pid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp capability_store_get(state, capability_id) do
    case supervised_registered_child_pid(state, CapabilityStore, CapabilityStore) do
      pid when is_pid(pid) -> GenServer.call(pid, {:get, capability_id})
      _ -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp registry_identity_status(state, principal_id) do
    case supervised_registered_child_pid(state, Registry, Registry) do
      pid when is_pid(pid) -> GenServer.call(pid, {:get_status, principal_id})
      _ -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp registry_lookup(state, principal_id) do
    case supervised_registered_child_pid(state, Registry, Registry) do
      pid when is_pid(pid) -> GenServer.call(pid, {:lookup, principal_id})
      _ -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp verify_capability_signature(state, capability) do
    case supervised_registered_child_pid(state, SystemAuthority, SystemAuthority) do
      pid when is_pid(pid) -> SystemAuthority.verify_capability_signature(capability)
      _ -> {:error, :invalid_capability_signature}
    end
  catch
    :exit, _ -> {:error, :invalid_capability_signature}
  end

  defp sign_receipt(state, receipt) do
    case supervised_registered_child_pid(state, SystemAuthority, SystemAuthority) do
      pid when is_pid(pid) -> SystemAuthority.sign_receipt_from_broker(receipt)
      _ -> {:error, :receipt_signing_unavailable}
    end
  catch
    :exit, _ -> {:error, :receipt_signing_unavailable}
  end
end
