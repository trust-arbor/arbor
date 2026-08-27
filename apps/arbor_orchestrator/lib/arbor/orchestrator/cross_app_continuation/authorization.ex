defmodule Arbor.Orchestrator.CrossAppContinuation.Authorization do
  @moduledoc false

  alias Arbor.Actions
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.CrossAppContinuation.Envelope
  alias Arbor.Orchestrator.CrossAppContinuation.Journal

  @prefix "arbor://orchestrator/cross_app_continuation"
  @fresh_keys ~w(identities planned_batches per_batch_budget_ms static_stage_receipt_digest)
  @mutations %{
    "claim" => :claim,
    "accept_passed_receipt" => :accept_passed_receipt,
    "accept_capacity_handoff" => :accept_capacity_handoff,
    "fail" => :fail,
    "cancel" => :cancel,
    "expire_claim" => :expire_claim,
    "revoke_claim" => :revoke_claim,
    "complete" => :complete
  }

  @spec open(map(), String.t(), SigningAuthority.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def open(input, caller_id, authority, opts) do
    with {:ok, journal_opts} <- admit_opts(opts),
         {:ok, operation_id} <- input_operation_id(input),
         {:ok, snapshot} <- admit_fresh_input(input),
         :ok <- bind_principal(snapshot, caller_id),
         {:ok, continuation_id} <-
           Actions.coding_cross_app_continuation_lineage_key(snapshot),
         {:ok, resource} <- resource(continuation_id, "open", operation_id),
         :ok <- authorize(caller_id, authority, resource) do
      Journal.open(input, journal_opts)
    end
  end

  @spec get(String.t(), String.t(), SigningAuthority.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get(continuation_id, caller_id, authority, opts) do
    with {:ok, journal_opts} <- admit_opts(opts),
         {:ok, resource} <- resource(continuation_id, "get"),
         :ok <- authorize(caller_id, authority, resource),
         :ok <- bind_durable_subject(continuation_id, caller_id, journal_opts) do
      Journal.get(continuation_id, journal_opts)
    end
  end

  @spec mutate(String.t(), String.t(), map(), String.t(), SigningAuthority.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate(operation, continuation_id, input, caller_id, authority, opts) do
    with {:ok, journal_opts} <- admit_opts(opts),
         {:ok, journal_fun} <- mutation_fun(operation),
         {:ok, operation_id} <- input_operation_id(input),
         {:ok, resource} <- resource(continuation_id, operation, operation_id),
         :ok <- authorize(caller_id, authority, resource),
         :ok <- bind_durable_subject(continuation_id, caller_id, journal_opts) do
      apply(Journal, journal_fun, [continuation_id, input, journal_opts])
    end
  end

  @spec durability_status(String.t(), SigningAuthority.t(), keyword()) ::
          map() | {:error, term()}
  def durability_status(caller_id, authority, opts) do
    with {:ok, journal_opts} <- admit_opts(opts),
         :ok <- authorize(caller_id, authority, @prefix <> "/journal/durability_status") do
      Journal.durability_status(journal_opts)
    end
  end

  @spec refresh(String.t(), SigningAuthority.t(), keyword()) :: :ok | {:error, term()}
  def refresh(caller_id, authority, opts) do
    with {:ok, journal_opts} <- admit_opts(opts),
         :ok <- authorize(caller_id, authority, @prefix <> "/journal/refresh") do
      Journal.refresh(journal_opts)
    end
  end

  @doc false
  @spec resource(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def resource(continuation_id, operation, operation_id \\ nil) do
    with {:ok, continuation_id} <- Envelope.continuation_id(continuation_id),
         :ok <- validate_operation(operation, operation_id) do
      suffix =
        if is_nil(operation_id),
          do: "#{continuation_id}/#{operation}",
          else: "#{continuation_id}/#{operation}/#{operation_id}"

      {:ok, @prefix <> "/" <> suffix}
    end
  end

  @doc false
  @spec open_resource(map()) :: {:ok, String.t()} | {:error, term()}
  def open_resource(input) do
    with {:ok, operation_id} <- input_operation_id(input),
         {:ok, snapshot} <- admit_fresh_input(input),
         {:ok, continuation_id} <-
           Actions.coding_cross_app_continuation_lineage_key(snapshot) do
      resource(continuation_id, "open", operation_id)
    end
  end

  defp admit_fresh_input(input) when is_map(input) and not is_struct(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(["operation_id" | @fresh_keys]) and
         Enum.all?(Map.keys(input), &is_binary/1) do
      input
      |> Map.drop(["operation_id"])
      |> Actions.coding_cross_app_continuation_new()
    else
      {:error, :malformed_state}
    end
  end

  defp admit_fresh_input(_input), do: {:error, :malformed_state}

  defp input_operation_id(input) when is_map(input) and not is_struct(input),
    do: Envelope.operation_id(Map.get(input, "operation_id"))

  defp input_operation_id(_input), do: {:error, :malformed_operation_id}

  defp bind_principal(%{"identities" => %{"principal_id" => caller_id}}, caller_id),
    do: :ok

  defp bind_principal(_snapshot, _caller_id), do: {:error, :subject_principal_mismatch}

  defp bind_durable_subject(continuation_id, caller_id, journal_opts) do
    case Journal.subject(continuation_id, journal_opts) do
      {:ok,
       %{
         "continuation_id" => ^continuation_id,
         "principal_id" => ^caller_id,
         "task_id" => task_id
       }}
      when is_binary(task_id) and task_id != "" ->
        :ok

      {:ok, _subject} ->
        {:error, :subject_principal_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize(caller_id, authority, resource) do
    with {:ok, canonical} <- SigningAuthority.canonicalize(authority),
         true <- canonical.principal_id == caller_id,
         {:ok, signed_request} <- Arbor.Security.sign_with_authority(canonical, resource) do
      case Arbor.Security.authorize(
             caller_id,
             resource,
             :execute,
             signed_request: signed_request
           ) do
        {:ok, :authorized} -> :ok
        {:ok, :pending_approval, proposal_id} -> {:error, {:pending_approval, proposal_id}}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_authorization_result, other}}
      end
    else
      false -> {:error, :principal_mismatch}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :security_unavailable}
    end
  rescue
    _error -> {:error, :security_unavailable}
  catch
    :exit, _reason -> {:error, :security_unavailable}
    _kind, _reason -> {:error, :security_unavailable}
  end

  defp admit_opts(opts) when is_list(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
         Enum.all?(keys, &(&1 == :server)) do
      {:ok, opts}
    else
      {:error, :invalid_options}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp admit_opts(_opts), do: {:error, :invalid_options}

  defp mutation_fun(operation) do
    case Map.fetch(@mutations, operation) do
      {:ok, fun} -> {:ok, fun}
      :error -> {:error, :invalid_operation}
    end
  end

  defp validate_operation("get", nil), do: :ok

  defp validate_operation(operation, operation_id)
       when operation == "open" or is_map_key(@mutations, operation) do
    case Envelope.operation_id(operation_id) do
      {:ok, _operation_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_operation(_operation, _operation_id), do: {:error, :invalid_operation}
end
