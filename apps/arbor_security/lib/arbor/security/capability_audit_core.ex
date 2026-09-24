defmodule Arbor.Security.CapabilityAuditCore do
  @moduledoc """
  Pure construction and observation of exact capability mutation intents.

  V2 fingerprints bind the complete serialized capability (including signature,
  chain and metadata), physical Record identity and backend incarnation. They
  are audit identity, never permission or proof against an offline store writer.
  Time enters from the serialized mutation owner.
  """

  alias Arbor.Contracts.Coding.CanonicalJson
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.Contracts.AuditJournal

  def fingerprint(:absent), do: {:ok, %{"kind" => "absent"}}

  def fingerprint({:tombstone, generation}),
    do: {:ok, %{"kind" => "tombstone", "generation" => generation}}

  def fingerprint(%Record{} = record) do
    with {:ok, bytes} <- CanonicalJson.encode(record.data) do
      {:ok,
       %{
         "kind" => "live",
         "record_id" => record.id,
         "generation" => record.generation,
         "revision" => record.revision,
         "capability_digest" => digest("arbor.security.capability_record.v2\0" <> bytes)
       }}
    end
  end

  def fingerprint(_), do: {:error, :invalid_record}

  def replacement(%Record{} = proposed, %Record{} = before) do
    %{proposed | id: before.id, generation: before.generation, revision: before.revision + 1}
  end

  def replacement(%Record{} = proposed, before) do
    generation =
      case before do
        :absent -> 1
        {:tombstone, previous} -> previous + 1
      end

    {:ok, data} = CanonicalJson.encode(proposed.data)

    id =
      digest(
        "arbor.security.capability_record_id.v2\0" <>
          proposed.key <> ":" <> Integer.to_string(generation) <> ":" <> data
      )

    %{proposed | id: "audit_" <> id, generation: generation, revision: 1}
  end

  def intent(operation, before, after_entry, data, now, correlation \\ nil) do
    with {:ok, before_fence} <- fingerprint(before),
         {:ok, after_fingerprint} <- fingerprint(after_entry) do
      {name, class, event} =
        case operation do
          :grant -> {"capability_grant", "authority_increase", "capability_granted"}
          :revoke -> {"capability_revoke", "authority_reduce", "capability_revoked"}
        end

      facts = %{
        "version" => 2,
        "kind" => "arbor.security.authority_mutation_intent.v2",
        "operation" => name,
        "effect_class" => class,
        "authority_namespace" => "capability",
        "authority_key" => data["id"],
        "before_fence" => before_fence,
        "after_fingerprint" => after_fingerprint,
        "prepared_at" => now,
        "audit" => %{
          "event_type" => event,
          "data" => %{
            "capability_id" => data["id"],
            "principal_id" => data["principal_id"],
            "resource_uri" => data["resource_uri"]
          }
        }
      }

      facts =
        if is_nil(correlation), do: facts, else: Map.put(facts, "correlation_id", correlation)

      AuditJournal.admit_intent(facts)
    end
  end

  def observation(intent, current) do
    after_fingerprint = intent["after_fingerprint"]
    before_fence = intent["before_fence"]

    case fingerprint(current) do
      {:ok, ^after_fingerprint} -> :applied
      {:ok, ^before_fence} -> {:rejected, "before_mismatch"}
      # A different incarnation may have superseded a real, transient effect.
      # Current occupancy alone cannot establish that it never happened.
      {:ok, _} -> :unknown
      _ -> :unknown
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
