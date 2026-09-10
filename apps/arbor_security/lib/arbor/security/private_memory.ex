defmodule Arbor.Security.PrivateMemory do
  @moduledoc false

  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Security
  alias Arbor.Security.Contracts.PrivateMemoryAdmission
  alias Arbor.Security.Contracts.PrivateMemoryRecord
  alias Arbor.Security.Contracts.PrivateMemorySource
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.SystemAuthority

  def exchange(receipt, agent_id, sender_id, context) do
    case DeliveryReceipt.bearer_token(receipt) do
      {:ok, token} -> exchange_token(token, agent_id, sender_id, context)
      _ -> {:error, :invalid_memory_admission}
    end
  end

  defp exchange_token(token, agent_id, sender_id, context) do
    with true <- scalar?(agent_id) and scalar?(sender_id),
         true <- is_map(context) and Enum.sort(Map.keys(context)) == [:session_id, :turn_id],
         true <- scalar?(context.session_id) and scalar?(context.turn_id) do
      DeliveryReceiptBroker.memory_exchange(token, agent_id, sender_id, context)
    else
      _ ->
        DeliveryReceiptBroker.discard(token)
        {:error, :invalid_memory_admission}
    end
  end

  def activate(admission, engagement_id) do
    with {:ok, token} <- PrivateMemoryAdmission.token(admission),
         true <- scalar?(engagement_id) do
      DeliveryReceiptBroker.memory_activate(token, engagement_id)
    else
      _ -> {:error, :invalid_memory_admission}
    end
  end

  def close(admission) do
    with {:ok, token} <- PrivateMemoryAdmission.token(admission),
         do: DeliveryReceiptBroker.memory_close(token)
  end

  def authorize(admission, operation) when operation in [:read, :write] do
    with {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_scope(token),
         :ok <- authorize_scope(scope, operation),
         {:ok, ^scope} <- DeliveryReceiptBroker.memory_scope(token) do
      {:ok, scope}
    else
      {:error, :broker_unavailable} = error -> error
      _ -> {:error, :invalid_memory_admission}
    end
  end

  def authorize(_, _), do: {:error, :invalid_memory_admission}

  # Source-owned scope only. SystemAuthority uses this in its bounded worker
  # because capability verification calls back into the root authority.
  def authorize_scope(scope, operation) when operation in [:read, :write] do
    with {:ok, :active} <- Security.identity_status(scope.agent_id),
         {:ok, :active} <- Security.identity_status(scope.human_id),
         {:ok, :authorized} <-
           Security.authorize(scope.human_id, "arbor://chat/agent/" <> scope.agent_id, :chat,
             verify_identity: false
           ),
         {:ok, :authorized} <- authorize_agent_memory(scope, operation) do
      :ok
    else
      {:error, :broker_unavailable} = error -> error
      _ -> {:error, :invalid_memory_admission}
    end
  rescue
    _ -> {:error, :invalid_memory_admission}
  catch
    _, _ -> {:error, :invalid_memory_admission}
  end

  def authorize_scope(_, _), do: {:error, :invalid_memory_admission}

  def attest(admission, descriptor) do
    with {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_scope(token),
         :ok <- PrivateMemoryRecord.admit(descriptor),
         true <- PrivateMemoryRecord.scope_matches?(descriptor, scope) do
      SystemAuthority.attest_private_memory_record(admission, descriptor)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_memory_record}
    end
  end

  def verify(descriptor, stamp) do
    with :ok <- PrivateMemoryRecord.admit(descriptor),
         do: SystemAuthority.verify_private_memory_record(descriptor, stamp)
  end

  def attest_source(admission, descriptor) do
    with {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_scope(token),
         :ok <- PrivateMemorySource.admit(descriptor),
         true <- PrivateMemorySource.scope_matches?(descriptor, scope) do
      SystemAuthority.attest_private_memory_source(admission, descriptor)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_memory_source}
    end
  end

  def verify_source(descriptor, stamp) do
    with :ok <- PrivateMemorySource.admit(descriptor),
         do: SystemAuthority.verify_private_memory_source(descriptor, stamp)
  end

  def attest_record_from_source(admission, descriptor, source, stamp) do
    with {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_scope(token),
         true <- PrivateMemorySource.binds_record?(source, descriptor),
         true <- PrivateMemorySource.pair_matches?(source, scope) do
      SystemAuthority.attest_private_memory_record_from_source(
        admission,
        descriptor,
        source,
        stamp
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_memory_source}
    end
  end

  def scalar?(value) when is_binary(value) do
    byte_size(value) in 1..256 and String.valid?(value) and
      String.trim(value) == value and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  def scalar?(_), do: false

  defp authorize_agent_memory(scope, operation) do
    parent = "arbor://memory/" <> Atom.to_string(operation)

    Security.authorize_self_scoped(
      scope.agent_id,
      parent <> "/" <> scope.agent_id,
      scope.agent_id,
      parent,
      :execute,
      verify_identity: false,
      session_id: scope.session_id,
      task_id: scope.turn_id
    )
  end
end
