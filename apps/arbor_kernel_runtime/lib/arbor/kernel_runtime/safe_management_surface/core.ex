defmodule Arbor.KernelRuntime.SafeManagementSurface.Core do
  @moduledoc """
  Pure construct core for the temporary P1A safe-management surface.

  `project/1` admits a closed in-memory candidate of one activation
  receipt, a requested operation, and an injected authorization status.
  It returns a string-keyed decision document with effects as data.
  No Process, IO, Application, or time is consulted.

  A receipt is never bearer authority. `authorization_status` must be
  `"verified"` or the decision is denied with an existing activation
  public error. `architecture_status` is always `"blocked"` in this
  packet because the surface stays unwired: production Application.start
  is unchanged.
  """

  @schema "arbor.kernel_runtime.safe_management_surface.v1"
  @version 1

  @optional_drop ["observations"]
  @derived_keys ["architecture_status", "decision", "effects", "error"]

  @candidate_keys [
    "authorization_status",
    "operation",
    "receipt",
    "schema",
    "version"
  ]

  @document_keys [
    "architecture_status",
    "authorization_status",
    "decision",
    "effects",
    "error",
    "operation",
    "receipt",
    "schema",
    "version"
  ]

  @receipt_keys [
    "artifact_sha256",
    "cleanup_disposition",
    "effects",
    "generation",
    "intent_sha256",
    "principal_id",
    "schema",
    "state",
    "transaction_id",
    "transaction_sha256",
    "version"
  ]

  @receipt_effect_keys ["class", "id", "state"]
  @mutation_keys ["kind", "transaction_id"]

  @operations MapSet.new(["clean", "disable", "list", "revoke", "rollback"])
  @authorization_statuses MapSet.new(["absent", "invalid", "revoked", "verified"])
  @decisions MapSet.new(["admitted", "denied"])

  @authorization_errors %{
    "absent" => "authorization_absent",
    "invalid" => "authorization_invalid",
    "revoked" => "authorization_revoked"
  }

  @decision_errors MapSet.new([
                     "authorization_absent",
                     "authorization_invalid",
                     "authorization_revoked",
                     "not_ready"
                   ])

  @cleanup MapSet.new(["none", "pending", "quarantined"])
  @receipt_states MapSet.new(["committed", "quarantined", "rolled_back"])
  @effect_classes MapSet.new(["compensable", "irreversible_audited", "reversible"])
  @effect_states MapSet.new(["applied", "quarantined", "rolled_back"])
  @mutation_kinds MapSet.new(["clean", "disable", "revoke", "rollback"])

  @receipt_schema "arbor.extension.activation_receipt.v1"
  @max_effects 32
  @max_string 256

  @doc "Closed safe-management surface schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Admit a closed candidate and return the decision document."
  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(candidate) when is_map(candidate) and not is_struct(candidate) do
    case admit_candidate(candidate) do
      {:ok, admitted} ->
        document = assemble(admitted)

        case validate_document(document) do
          :ok -> {:ok, document}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  def project(_), do: {:error, :invalid_candidate}

  defp admit_candidate(candidate) do
    dropped = Map.drop(candidate, @optional_drop ++ @derived_keys)

    with :ok <- exact_keys(dropped, @candidate_keys),
         :ok <- exact(dropped["schema"], @schema),
         :ok <- exact(dropped["version"], @version),
         :ok <- member(dropped["operation"], @operations),
         :ok <- member(dropped["authorization_status"], @authorization_statuses),
         {:ok, receipt} <- admit_receipt(dropped["receipt"]) do
      {:ok, %{dropped | "receipt" => receipt}}
    end
  end

  defp assemble(candidate) do
    {decision, error, effects} =
      decide(
        candidate["operation"],
        candidate["authorization_status"],
        candidate["receipt"]
      )

    %{
      "schema" => @schema,
      "version" => @version,
      "operation" => candidate["operation"],
      "authorization_status" => candidate["authorization_status"],
      "receipt" => candidate["receipt"],
      "decision" => decision,
      "error" => error,
      "effects" => effects,
      # Always blocked: an admitted decision is not a wired surface.
      "architecture_status" => "blocked"
    }
  end

  defp decide(_operation, status, _receipt) when is_map_key(@authorization_errors, status) do
    {"denied", Map.fetch!(@authorization_errors, status), []}
  end

  defp decide("list", "verified", _receipt), do: {"admitted", nil, []}

  defp decide("revoke", "verified", receipt) do
    {"admitted", nil, [mutation("revoke", receipt)]}
  end

  defp decide("disable", "verified", receipt) do
    {"admitted", nil, [mutation("disable", receipt)]}
  end

  defp decide("rollback", "verified", receipt) do
    if irreversible?(receipt) do
      {"denied", "not_ready", []}
    else
      {"admitted", nil, [mutation("rollback", receipt)]}
    end
  end

  defp decide("clean", "verified", receipt) do
    if receipt["cleanup_disposition"] == "pending" do
      {"admitted", nil, [mutation("clean", receipt)]}
    else
      {"denied", "not_ready", []}
    end
  end

  defp mutation(kind, receipt) do
    %{"kind" => kind, "transaction_id" => receipt["transaction_id"]}
  end

  defp irreversible?(receipt) do
    Enum.any?(receipt["effects"], fn effect ->
      effect["class"] == "irreversible_audited"
    end)
  end

  defp validate_document(document) do
    with :ok <- exact_keys(document, @document_keys),
         :ok <- exact(document["schema"], @schema),
         :ok <- exact(document["version"], @version),
         :ok <- member(document["operation"], @operations),
         :ok <- member(document["authorization_status"], @authorization_statuses),
         :ok <- exact(document["architecture_status"], "blocked"),
         :ok <- member(document["decision"], @decisions),
         :ok <- validate_error(document["error"]),
         :ok <- validate_mutations(document["effects"]),
         {:ok, _receipt} <- admit_receipt(document["receipt"]) do
      consistent_decision(document)
    end
  end

  defp validate_error(nil), do: :ok
  defp validate_error(error), do: member(error, @decision_errors)

  defp consistent_decision(%{"decision" => "admitted", "error" => nil}), do: :ok

  defp consistent_decision(%{"decision" => "denied", "error" => error, "effects" => []})
       when is_binary(error) do
    :ok
  end

  defp consistent_decision(_document), do: {:error, :inconsistent_decision}

  defp admit_receipt(receipt) when is_map(receipt) and not is_struct(receipt) do
    with :ok <- exact_keys(receipt, @receipt_keys),
         :ok <- exact(receipt["schema"], @receipt_schema),
         :ok <- exact(receipt["version"], @version),
         :ok <- token(receipt["transaction_id"]),
         :ok <- member(receipt["cleanup_disposition"], @cleanup),
         :ok <- member(receipt["state"], @receipt_states),
         :ok <- validate_receipt_effects(receipt["effects"]) do
      {:ok, receipt}
    else
      {:error, reason} -> {:error, {:invalid_field, "receipt", reason}}
    end
  end

  defp admit_receipt(_), do: {:error, {:invalid_field, "receipt", :invalid_map}}

  defp validate_receipt_effects(list) do
    case take_proper_list(list, @max_effects) do
      {:ok, []} ->
        {:error, :empty_list}

      {:ok, items} ->
        Enum.reduce_while(items, {:ok, MapSet.new()}, fn item, {:ok, seen} ->
          case admit_receipt_effect(item, seen) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, _seen} -> :ok
          {:error, _} = error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admit_receipt_effect(effect, seen) when is_map(effect) and not is_struct(effect) do
    with :ok <- exact_keys(effect, @receipt_effect_keys),
         :ok <- token(effect["id"]),
         :ok <- member(effect["class"], @effect_classes),
         :ok <- member(effect["state"], @effect_states) do
      if MapSet.member?(seen, effect["id"]) do
        {:error, :duplicate}
      else
        {:ok, MapSet.put(seen, effect["id"])}
      end
    end
  end

  defp admit_receipt_effect(_effect, _seen), do: {:error, :invalid_map}

  defp validate_mutations(list) do
    case take_proper_list(list, @max_effects) do
      {:ok, items} ->
        Enum.reduce_while(items, :ok, fn item, :ok ->
          case admit_mutation(item) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_field, "effects", reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:invalid_field, "effects", reason}}
    end
  end

  defp admit_mutation(effect) when is_map(effect) and not is_struct(effect) do
    with :ok <- exact_keys(effect, @mutation_keys),
         :ok <- member(effect["kind"], @mutation_kinds) do
      token(effect["transaction_id"])
    end
  end

  defp admit_mutation(_), do: {:error, :invalid_map}

  defp exact_keys(map, keys) when is_map(map) and not is_struct(map) do
    actual = Map.keys(map)

    cond do
      Enum.any?(actual, &is_atom/1) and Enum.any?(actual, &is_binary/1) ->
        {:error, :mixed_keys}

      Enum.any?(actual, &(not is_binary(&1))) ->
        {:error, :non_string_keys}

      Enum.sort(actual) == Enum.sort(keys) ->
        :ok

      true ->
        {:error, :closed_keys}
    end
  end

  defp exact_keys(_, _), do: {:error, :invalid_map}

  defp exact(value, value), do: :ok
  defp exact(_, _), do: {:error, :exact_mismatch}

  defp member(value, set) do
    if MapSet.member?(set, value), do: :ok, else: {:error, :invalid_member}
  end

  defp token(value) when is_binary(value) do
    cond do
      value == "" -> {:error, :empty_string}
      byte_size(value) > @max_string -> {:error, :unbounded}
      not String.valid?(value) -> {:error, :invalid_utf8}
      String.contains?(value, <<0>>) -> {:error, :invalid_string}
      true -> :ok
    end
  end

  defp token(_), do: {:error, :not_a_string}

  defp take_proper_list(list, max) when is_list(list) and is_integer(max) do
    take_proper_list(list, max, 0, [])
  end

  defp take_proper_list(_, _), do: {:error, :not_a_list}

  defp take_proper_list([], _max, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_proper_list([head | tail], max, count, acc) do
    if count >= max do
      {:error, :unbounded}
    else
      take_proper_list(tail, max, count + 1, [head | acc])
    end
  end

  defp take_proper_list(_, _, _, _), do: {:error, :improper_list}
end
