defmodule Arbor.Security.Contracts.AuditJournalTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @cap_id "cap_" <> String.duplicate("a", 32)
  @prepared_at "2026-08-20T12:00:00Z"
  @forbidden ~w(
    capability token secret password private_key issuer_signature signing_key
    bearer credentials callback metadata terms prose note reason_text
    constraints delegation_chain
  )

  describe "enumerations and limits" do
    test "exposes closed v1 vocabularies and per-object maxima" do
      assert AuditJournal.version() == 1
      assert AuditJournal.intent_kind() == "arbor.security.authority_mutation_intent.v1"
      assert AuditJournal.record_kind() == "arbor.security.authority_mutation_record.v1"
      assert AuditJournal.operations() == ["capability_grant", "capability_revoke"]
      assert AuditJournal.effect_classes() == ["authority_increase", "authority_reduce"]
      assert AuditJournal.namespaces() == ["capability"]

      assert AuditJournal.record_types() ==
               ["prepared", "effect_applied", "effect_rejected", "delivered"]

      limits = AuditJournal.limits()
      assert limits.max_record_bytes == 32_768
      assert limits.hard_entry_cap == 48
      assert limits.max_fold_records == 48
      assert limits.reserve_entries == 16
      assert limits.soft_entry_cap == 32
      assert limits.max_keys.intent == 16
      assert limits.max_keys.live == 5
    end

    test "forbidden names are absent from every allowed keyset" do
      allowed =
        MapSet.new(~w(version kind operation effect_class authority_namespace authority_key
             before_fence after_fingerprint audit prepared_at actor_id task_id
             session_id correlation_id causation_id operation_id record_type
             occurred_at intent observation event_type data capability_id
             principal_id resource_uri expires_at record_id generation revision
             capability_digest reason))

      for name <- @forbidden do
        refute name in allowed
      end
    end

    test "effect_class_for is fixed" do
      assert AuditJournal.effect_class_for("capability_grant") == {:ok, "authority_increase"}
      assert AuditJournal.effect_class_for("capability_revoke") == {:ok, "authority_reduce"}

      assert AuditJournal.effect_class_for("identity_register") ==
               {:error, :unsupported_operation}
    end
  end

  describe "admit_intent/1 allowed mappings" do
    test "admits capability_grant with absent then live generation 1" do
      assert {:ok, intent} = AuditJournal.admit_intent(grant_facts())
      assert intent["operation"] == "capability_grant"
      assert intent["effect_class"] == "authority_increase"
      assert intent["authority_namespace"] == "capability"
      assert intent["authority_key"] == @cap_id
      assert byte_size(intent["operation_id"]) == 64
      refute Map.has_key?(intent, "actor_id")
    end

    test "admits capability_grant after tombstone with exact parent generation successor" do
      facts =
        grant_facts()
        |> Map.put("before_fence", %{"kind" => "tombstone", "generation" => 4})
        |> put_in(["after_fingerprint", "generation"], 5)

      assert {:ok, intent} = AuditJournal.admit_intent(facts)
      assert intent["before_fence"]["generation"] == 4
      assert intent["after_fingerprint"]["generation"] == 5
    end

    test "admits capability_revoke live then tombstone" do
      assert {:ok, intent} = AuditJournal.admit_intent(revoke_facts())
      assert intent["operation"] == "capability_revoke"
      assert intent["effect_class"] == "authority_reduce"
      assert intent["audit"]["event_type"] == "capability_revoked"
    end

    test "admits a fully populated 16-key intent including matching operation_id" do
      facts =
        grant_facts()
        |> Map.merge(%{
          "actor_id" => "actor_1",
          "task_id" => "task_1",
          "session_id" => "session_1",
          "correlation_id" => "corr_1",
          "causation_id" => "cause_1"
        })

      assert {:ok, operation_id} = AuditJournal.operation_id(facts)
      populated = Map.put(facts, "operation_id", operation_id)

      assert map_size(populated) == 16
      assert {:ok, intent} = AuditJournal.admit_intent(populated)
      assert map_size(intent) == 16
      assert intent["operation_id"] == operation_id
      assert intent["actor_id"] == "actor_1"
    end

    test "admits grant audit expires_at" do
      facts = put_in(grant_facts(), ["audit", "data", "expires_at"], "2026-12-31T23:59:59Z")
      assert {:ok, intent} = AuditJournal.admit_intent(facts)
      assert intent["audit"]["data"]["expires_at"] == "2026-12-31T23:59:59Z"
    end
  end

  describe "admit_intent/1 rejected classes" do
    test "rejects a 17th key" do
      {:ok, admitted} = AuditJournal.admit_intent(grant_facts())

      sixteen =
        grant_facts()
        |> Map.merge(%{
          "actor_id" => "actor_1",
          "task_id" => "task_1",
          "session_id" => "session_1",
          "correlation_id" => "corr_1",
          "causation_id" => "cause_1",
          "operation_id" => admitted["operation_id"]
        })

      assert map_size(sixteen) == 16

      assert {:error, reason} = AuditJournal.admit_intent(Map.put(sixteen, "extra", "nope"))
      assert reason in [:malformed, :unknown_field]
    end

    test "rejects missing required field" do
      assert {:error, :missing_field} =
               AuditJournal.admit_intent(Map.delete(grant_facts(), "audit"))
    end

    test "rejects unknown field within max keys" do
      facts = grant_facts() |> Map.delete("prepared_at") |> Map.put("note", "x")
      assert {:error, reason} = AuditJournal.admit_intent(facts)
      assert reason in [:unknown_field, :forbidden_content, :missing_field]
    end

    test "rejects atom keys" do
      mixed = Map.put(grant_facts(), :version, 1)

      assert {:error, :atom_key_not_allowed} = AuditJournal.admit_intent(mixed)
    end

    test "rejects structs" do
      assert {:error, :struct_not_allowed} = AuditJournal.admit_intent(%URI{})
    end

    test "rejects keyword lists" do
      assert {:error, :invalid_object} = AuditJournal.admit_intent(version: 1)
    end

    test "rejects null optional as invalid rather than omit" do
      assert {:error, :invalid_field} =
               AuditJournal.admit_intent(Map.put(grant_facts(), "actor_id", nil))
    end

    test "rejects empty identifier" do
      facts = put_in(grant_facts(), ["audit", "data", "principal_id"], "")
      assert {:error, :invalid_field} = AuditJournal.admit_intent(facts)
    end

    test "rejects non-UTF8 principal" do
      facts = put_in(grant_facts(), ["audit", "data", "principal_id"], <<0xFF>>)
      assert {:error, :invalid_utf8} = AuditJournal.admit_intent(facts)
    end

    test "rejects float generation" do
      facts = put_in(grant_facts(), ["after_fingerprint", "generation"], 1.0)
      assert {:error, :float_not_allowed} = AuditJournal.admit_intent(facts)
    end

    test "rejects oversized resource_uri" do
      facts =
        put_in(
          grant_facts(),
          ["audit", "data", "resource_uri"],
          String.duplicate("r", 2049)
        )

      assert {:error, :invalid_field} = AuditJournal.admit_intent(facts)
    end

    test "rejects control characters" do
      facts = put_in(grant_facts(), ["audit", "data", "principal_id"], "agent\n1")
      assert {:error, {:invalid_field, "principal_id"}} = AuditJournal.admit_intent(facts)
    end

    test "rejects non-capability namespace" do
      assert {:error, :unsupported_operation} =
               AuditJournal.admit_intent(
                 Map.put(grant_facts(), "authority_namespace", "identity")
               )
    end

    test "rejects unknown operation" do
      assert {:error, :unsupported_operation} =
               AuditJournal.admit_intent(
                 Map.put(grant_facts(), "operation", "capability_delegate")
               )
    end

    test "rejects caller-selected effect_class" do
      assert {:error, :effect_class_mismatch} =
               AuditJournal.admit_intent(
                 Map.put(grant_facts(), "effect_class", "authority_reduce")
               )
    end

    test "rejects audit event mismatch" do
      facts = put_in(grant_facts(), ["audit", "event_type"], "capability_revoked")
      assert {:error, :audit_event_mismatch} = AuditJournal.admit_intent(facts)
    end

    test "rejects unsupported version" do
      assert {:error, :unsupported_version} =
               AuditJournal.admit_intent(Map.put(grant_facts(), "version", 2))
    end

    test "enforces max_nodes after increment: 64 nodes pass budget, 65 fail closed" do
      max_nodes = AuditJournal.limits().max_nodes
      assert max_nodes == 64

      at_k =
        Enum.find(1..80, fn k ->
          count_nodes(nested_kind_facts(k)) == max_nodes
        end)

      refute is_nil(at_k)
      at_cap = nested_kind_facts(at_k)
      over_cap = nested_kind_facts(at_k + 1)
      assert count_nodes(at_cap) == 64
      assert count_nodes(over_cap) == 65

      assert {:error, {:invalid_field, "kind"}} = AuditJournal.admit_intent(at_cap)
      assert {:error, :malformed} = AuditJournal.admit_intent(over_cap)
    end

    test "bounds proper and improper list classification within max_nodes" do
      max_nodes = AuditJournal.limits().max_nodes

      exact_top_level = List.duplicate("x", max_nodes - 1)
      over_top_level = List.duplicate("x", max_nodes)
      assert {:error, :invalid_object} = AuditJournal.admit_intent(exact_top_level)
      assert {:error, :malformed} = AuditJournal.admit_intent(over_top_level)

      exact_nested = %{"x" => List.duplicate("x", max_nodes - 2)}
      over_nested = %{"x" => List.duplicate("x", max_nodes - 1)}
      assert {:error, :invalid_field} = AuditJournal.admit_intent(exact_nested)
      assert {:error, :malformed} = AuditJournal.admit_intent(over_nested)

      assert {:error, :improper_list} = AuditJournal.admit_intent(%{"x" => ["x" | :tail]})
    end

    test "checks byte caps before UTF-8 and grammar scans" do
      exact =
        grant_facts()
        |> put_in(["after_fingerprint", "record_id"], String.duplicate("r", 128))
        |> put_in(["after_fingerprint", "capability_digest"], String.duplicate("a", 64))
        |> put_in(["audit", "data", "principal_id"], String.duplicate("p", 256))
        |> put_in(["audit", "data", "resource_uri"], String.duplicate("r", 2_048))
        |> put_in(["audit", "data", "expires_at"], "2026-12-31T23:59:59Z")
        |> Map.merge(%{
          "actor_id" => String.duplicate("a", 256),
          "task_id" => String.duplicate("t", 256),
          "session_id" => String.duplicate("s", 256),
          "correlation_id" => String.duplicate("c", 128),
          "causation_id" => String.duplicate("d", 128)
        })

      assert {:ok, _intent} = AuditJournal.admit_intent(exact)

      oversized = fn max, byte -> String.duplicate("x", max) <> <<byte>> end

      cases = [
        {:invalid_field, Map.put(grant_facts(), "authority_key", oversized.(36, 0xFF))},
        {:invalid_field,
         put_in(grant_facts(), ["after_fingerprint", "record_id"], oversized.(128, 0xFF))},
        {:invalid_field,
         put_in(
           grant_facts(),
           ["after_fingerprint", "capability_digest"],
           oversized.(64, 0xFF)
         )},
        {:invalid_field,
         put_in(grant_facts(), ["audit", "data", "principal_id"], oversized.(256, 0xFF))},
        {:invalid_field,
         put_in(grant_facts(), ["audit", "data", "resource_uri"], oversized.(2_048, 0xFF))},
        {:invalid_field, Map.put(grant_facts(), "actor_id", oversized.(256, 0xFF))},
        {:invalid_field, Map.put(grant_facts(), "correlation_id", oversized.(128, 0xFF))},
        {{:invalid_field, "prepared_at"},
         Map.put(grant_facts(), "prepared_at", oversized.(20, 0xFF))},
        {{:invalid_field, "expires_at"},
         put_in(grant_facts(), ["audit", "data", "expires_at"], oversized.(20, 0xFF))},
        {{:invalid_field, "capability_id"},
         put_in(grant_facts(), ["audit", "data", "capability_id"], oversized.(36, 0xFF))}
      ]

      for {reason, facts} <- cases do
        assert {:error, ^reason} = AuditJournal.admit_intent(facts)
      end

      oversized_key = String.duplicate("k", 19) <> <<0xFF>>

      assert {:error, :unknown_field} =
               AuditJournal.admit_intent(Map.put(grant_facts(), oversized_key, "x"))
    end

    test "rejects non-canonical timestamps" do
      assert {:error, {:invalid_field, "prepared_at"}} =
               AuditJournal.admit_intent(
                 Map.put(grant_facts(), "prepared_at", "2026-08-20T12:00:00+00:00")
               )
    end

    test "rejects forbidden bearer/metadata keys" do
      assert {:error, :forbidden_content} =
               AuditJournal.admit_intent(Map.put(grant_facts(), "bearer", "tok"))

      assert {:error, :forbidden_content} =
               AuditJournal.admit_intent(Map.put(grant_facts(), "metadata", %{}))

      assert {:error, :forbidden_content} =
               AuditJournal.admit_intent(Map.put(grant_facts(), "capability", %{}))
    end

    test "rejects mismatched audit capability_id" do
      other = "cap_" <> String.duplicate("b", 32)
      facts = put_in(grant_facts(), ["audit", "data", "capability_id"], other)
      assert {:error, {:invalid_field, "capability_id"}} = AuditJournal.admit_intent(facts)
    end
  end

  describe "before_fence / after_fingerprint matrix" do
    @kinds ["absent", "live", "tombstone"]

    test "rejects every illegal grant pair" do
      live = live_fp(1)
      tombstone = %{"kind" => "tombstone", "generation" => 1}
      absent = %{"kind" => "absent"}

      shapes = %{"absent" => absent, "live" => live, "tombstone" => tombstone}

      for before <- @kinds, after_kind <- @kinds do
        legal? =
          (before == "absent" and after_kind == "live") or
            (before == "tombstone" and after_kind == "live")

        unless legal? do
          facts =
            grant_facts()
            |> Map.put("before_fence", shapes[before])
            |> Map.put("after_fingerprint", shapes[after_kind])

          assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(facts)
        end
      end
    end

    test "rejects every illegal revoke pair" do
      live = live_fp(3)
      tombstone = %{"kind" => "tombstone", "generation" => 3}
      absent = %{"kind" => "absent"}
      shapes = %{"absent" => absent, "live" => live, "tombstone" => tombstone}

      for before <- @kinds, after_kind <- @kinds do
        unless before == "live" and after_kind == "tombstone" do
          facts =
            revoke_facts()
            |> Map.put("before_fence", shapes[before])
            |> Map.put("after_fingerprint", shapes[after_kind])

          assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(facts)
        end
      end
    end

    test "rejects grant live successor with wrong generation or revision" do
      facts = put_in(grant_facts(), ["after_fingerprint", "generation"], 2)
      assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(facts)

      facts = put_in(grant_facts(), ["after_fingerprint", "revision"], 2)
      assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(facts)

      facts =
        grant_facts()
        |> Map.put("before_fence", %{"kind" => "tombstone", "generation" => 4})
        |> put_in(["after_fingerprint", "generation"], 4)

      assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(facts)

      facts = put_in(facts, ["after_fingerprint", "generation"], 6)
      assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(facts)
    end

    test "rejects revoke tombstone generation mismatch" do
      facts = put_in(revoke_facts(), ["after_fingerprint", "generation"], 2)
      assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(facts)
    end
  end

  describe "canonicalization and operation_id" do
    test "operation_id is domain-separated SHA-256 of facts excluding operation_id" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())
      {:ok, facts} = AuditJournal.canonical_intent_bytes(intent)
      {:ok, decoded} = Jason.decode(facts)
      refute Map.has_key?(decoded, "operation_id")

      expected =
        :crypto.hash(:sha256, AuditJournal.intent_domain() <> facts)
        |> Base.encode16(case: :lower)

      assert intent["operation_id"] == expected
      assert {:ok, expected} == AuditJournal.operation_id(grant_facts())
    end

    test "changing the domain NUL changes the digest" do
      {:ok, facts} = AuditJournal.canonical_intent_bytes(grant_facts())
      {:ok, op_id} = AuditJournal.operation_id(grant_facts())

      other =
        :crypto.hash(:sha256, "arbor.security.authority_mutation_intent.v1" <> facts)
        |> Base.encode16(case: :lower)

      refute other == op_id
    end

    test "input key order does not change canonical bytes or operation_id" do
      a = grant_facts()
      b = a |> Enum.reverse() |> Map.new()
      assert {:ok, bytes_a} = AuditJournal.canonical_intent_bytes(a)
      assert {:ok, bytes_b} = AuditJournal.canonical_intent_bytes(b)
      assert bytes_a == bytes_b
      assert AuditJournal.operation_id(a) == AuditJournal.operation_id(b)
    end

    test "canonical bytes use explicit field order" do
      {:ok, bytes} = AuditJournal.canonical_intent_bytes(grant_facts())
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())

      expected =
        Jason.encode!(
          Jason.OrderedObject.new([
            {"version", 1},
            {"kind", AuditJournal.intent_kind()},
            {"operation", "capability_grant"},
            {"effect_class", "authority_increase"},
            {"authority_namespace", "capability"},
            {"authority_key", @cap_id},
            {"before_fence", Jason.OrderedObject.new([{"kind", "absent"}])},
            {"after_fingerprint",
             Jason.OrderedObject.new([
               {"kind", "live"},
               {"record_id", "rec_1"},
               {"generation", 1},
               {"revision", 1},
               {"capability_digest", @digest}
             ])},
            {"audit",
             Jason.OrderedObject.new([
               {"event_type", "capability_granted"},
               {"data",
                Jason.OrderedObject.new([
                  {"capability_id", @cap_id},
                  {"principal_id", "agent_a"},
                  {"resource_uri", "arbor://fs/read/x"}
                ])}
             ])},
            {"prepared_at", @prepared_at}
          ])
        )

      assert bytes == expected
      refute String.contains?(bytes, intent["operation_id"])
    end

    test "supplied matching operation_id is accepted; mismatch is operation_id_mismatch" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())

      assert {:ok, _} =
               AuditJournal.admit_intent(
                 Map.put(grant_facts(), "operation_id", intent["operation_id"])
               )

      assert {:error, :operation_id_mismatch} =
               AuditJournal.admit_intent(
                 Map.put(grant_facts(), "operation_id", String.duplicate("0", 64))
               )
    end

    test "changing a fact byte changes operation_id" do
      {:ok, a} = AuditJournal.operation_id(grant_facts())
      other = put_in(grant_facts(), ["audit", "data", "principal_id"], "agent_b")
      {:ok, b} = AuditJournal.operation_id(other)
      refute a == b
    end
  end

  describe "admit_record/1" do
    test "admits prepared when record, intent, and derived ids agree" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())
      assert {:ok, record} = AuditJournal.admit_record(prepared(intent))
      assert record["record_type"] == "prepared"
      assert record["operation_id"] == intent["operation_id"]
    end

    test "prepared occurred_at must equal prepared_at" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())

      record =
        intent
        |> prepared()
        |> Map.put("occurred_at", "2026-08-21T00:00:00Z")

      assert {:error, {:invalid_field, "occurred_at"}} = AuditJournal.admit_record(record)
    end

    test "record vs nested intent operation_id disagreement is cross_operation" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())
      other = String.duplicate("c", 64)

      assert {:error, :cross_operation} =
               AuditJournal.admit_record(Map.put(prepared(intent), "operation_id", other))

      forged_intent = Map.put(intent, "operation_id", other)

      assert {:error, :cross_operation} =
               AuditJournal.admit_record(
                 prepared(intent)
                 |> Map.put("intent", forged_intent)
                 |> Map.put("operation_id", other)
               )
    end

    test "rejects indeterminate observations" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())

      for kind <- ["unavailable", "indeterminate", "unknown", "outcome_unknown"] do
        record = applied(intent, "2026-08-20T12:00:01Z", kind)

        assert {:error, :indeterminate_observation} = AuditJournal.admit_record(record),
               "kind #{kind}"
      end
    end

    test "admits applied, rejected, and delivered envelopes" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts())
      {:ok, revoke} = AuditJournal.admit_intent(revoke_facts())

      assert {:ok, _} = AuditJournal.admit_record(applied(intent, "2026-08-20T12:00:01Z"))
      assert {:ok, _} = AuditJournal.admit_record(rejected(revoke, "2026-08-20T12:00:01Z"))
      assert {:ok, _} = AuditJournal.admit_record(delivered(intent, "2026-08-20T12:00:02Z"))
    end
  end

  defp nested_kind_facts(scalar_count) do
    nested = Map.new(1..scalar_count, fn i -> {"n#{i}", "x"} end)
    Map.put(grant_facts(), "before_fence", %{"kind" => nested})
  end

  defp count_nodes(value), do: count_nodes(value, 0)

  defp count_nodes(map, acc) when is_map(map) and not is_struct(map) do
    Enum.reduce(Map.values(map), acc + 1, &count_nodes/2)
  end

  defp count_nodes(_scalar, acc), do: acc + 1

  defp grant_facts do
    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => @cap_id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => live_fp(1),
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => @cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp revoke_facts do
    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_revoke",
      "effect_class" => "authority_reduce",
      "authority_namespace" => "capability",
      "authority_key" => @cap_id,
      "before_fence" => live_fp(3),
      "after_fingerprint" => %{"kind" => "tombstone", "generation" => 3},
      "audit" => %{
        "event_type" => "capability_revoked",
        "data" => %{
          "capability_id" => @cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp live_fp(generation) do
    %{
      "kind" => "live",
      "record_id" => "rec_1",
      "generation" => generation,
      "revision" => 1,
      "capability_digest" => @digest
    }
  end

  defp prepared(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp applied(intent, occurred_at, observation_kind \\ "applied") do
    observation =
      if observation_kind == "applied" do
        %{"kind" => "applied", "after_fingerprint" => intent["after_fingerprint"]}
      else
        %{"kind" => observation_kind, "after_fingerprint" => intent["after_fingerprint"]}
      end

    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at,
      "observation" => observation
    }
  end

  defp rejected(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_rejected",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at,
      "observation" => %{"kind" => "rejected", "reason" => "before_mismatch"}
    }
  end

  defp delivered(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "delivered",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at
    }
  end
end
