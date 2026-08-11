defmodule Arbor.Agent.ProfileAuthorityMutationCoreTest do
  @moduledoc """
  Pure unit tests for `Arbor.Agent.ProfileAuthorityMutationCore`.

  Exercises preparation (overlay + preservation + every rejection rule),
  the pre-CAS envelope-stability predicate, and the full ambiguous-reobservation
  classification matrix. No stores are started.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.ProfileAuthorityMutationCore, as: Core
  alias Arbor.Contracts.Persistence.Record

  # ─────────────────────────────────────────────────────────────────────
  # Fixtures
  # ─────────────────────────────────────────────────────────────────────

  defp observed_data(opts \\ []) do
    base = %{
      "agent_id" => "agent_test_1",
      "version" => 1,
      "display_name" => "Scout Unit",
      "character" => %{"name" => "Scout"},
      "sandbox_level" => "strict",
      "initial_goals" => [],
      "identity" => nil,
      "keychain_ref" => nil,
      "auto_start" => false,
      "created_at" => "2026-01-01T00:00:00Z",
      "template" => "legacy_template",
      "initial_capabilities" => [
        %{"resource" => "arbor://legacy/read", "constraints" => %{}}
      ],
      "metadata" => %{
        "last_model_config" => %{"provider" => "ollama"},
        "external_agent" => true,
        "exact_template_policy" => %{"old" => true},
        "arbitrary_sibling" => "preserved"
      }
    }

    case Keyword.get(opts, :metadata) do
      nil -> base
      meta -> %{base | "metadata" => meta}
    end
  end

  defp governed(opts \\ []) do
    template = Keyword.get(opts, :template, "scout")

    capabilities =
      Keyword.get(
        opts,
        :initial_capabilities,
        [
          %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}}
        ]
      )

    policy =
      Keyword.get(opts, :exact_template_policy, %{"version" => 1, "markers" => []})

    %{
      "template" => template,
      "initial_capabilities" => capabilities,
      "metadata" => %{"exact_template_policy" => policy}
    }
  end

  defp record(data, gen, rev, opts \\ []) do
    %Record{
      id: Keyword.get(opts, :id, "rec_test"),
      key: Keyword.get(opts, :key, "agent_test_1"),
      data: data,
      metadata: Keyword.get(opts, :metadata, %{}),
      generation: gen,
      revision: rev,
      inserted_at: Keyword.get(opts, :inserted_at),
      updated_at: Keyword.get(opts, :updated_at)
    }
  end

  # ─────────────────────────────────────────────────────────────────────
  # prepare/2 — overlay + preservation
  # ─────────────────────────────────────────────────────────────────────

  describe "prepare/2 overlay and preservation" do
    test "overlays only the three governed fields" do
      observed = observed_data()
      {:ok, intended} = Core.prepare(observed, governed())

      assert intended["template"] == "scout"

      assert intended["initial_capabilities"] == [
               %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}}
             ]

      assert intended["metadata"]["exact_template_policy"] == %{
               "version" => 1,
               "markers" => []
             }
    end

    test "preserves every unrelated top-level field" do
      observed = observed_data()
      {:ok, intended} = Core.prepare(observed, governed())

      for key <- [
            "agent_id",
            "version",
            "display_name",
            "character",
            "sandbox_level",
            "initial_goals",
            "identity",
            "keychain_ref",
            "auto_start",
            "created_at"
          ] do
        assert intended[key] == observed[key], "unrelated top-level #{key} must be preserved"
      end
    end

    test "preserves every unrelated nested metadata field" do
      observed = observed_data()
      {:ok, intended} = Core.prepare(observed, governed())

      assert intended["metadata"]["last_model_config"] == %{"provider" => "ollama"}
      assert intended["metadata"]["external_agent"] == true
      assert intended["metadata"]["arbitrary_sibling"] == "preserved"
    end

    test "preserves governed top-level fields it did not touch by reference" do
      observed = observed_data()
      original_meta = observed["metadata"]
      {:ok, intended} = Core.prepare(observed, governed())

      # Original observed metadata is not mutated in place.
      assert observed["metadata"] == original_meta
      # And unrelated metadata keys round-trip byte-identical.
      for k <- Map.keys(original_meta) -- ["exact_template_policy"] do
        assert intended["metadata"][k] == original_meta[k]
      end
    end

    test "initial_capabilities items are stored verbatim (no stripping)" do
      item = %{
        "resource" => "arbor://fs/write",
        "constraints" => %{"requires_approval" => true},
        "source" => "extra_field_kept"
      }

      {:ok, intended} =
        Core.prepare(observed_data(), governed(initial_capabilities: [item]))

      assert intended["initial_capabilities"] == [item]
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # prepare/2 — malformed containers and structs
  # ─────────────────────────────────────────────────────────────────────

  describe "prepare/2 malformed-container rejection" do
    test "rejects observed_data that is not a plain map" do
      assert {:error, :observed_not_map} = Core.prepare("not a map", governed())
      assert {:error, :observed_not_map} = Core.prepare(nil, governed())

      assert {:error, :observed_not_map} =
               Core.prepare(%Record{id: "x", key: "y", data: %{}}, governed())
    end

    test "rejects missing observed metadata (no defaulting to %{})" do
      observed = Map.delete(observed_data(), "metadata")
      assert {:error, :malformed_container} = Core.prepare(observed, governed())
    end

    test "rejects nil observed metadata (no defaulting to %{})" do
      observed = %{observed_data() | "metadata" => nil}
      assert {:error, :malformed_container} = Core.prepare(observed, governed())
    end

    test "rejects scalar observed metadata" do
      observed = %{observed_data() | "metadata" => "scalar"}
      assert {:error, :malformed_container} = Core.prepare(observed, governed())
    end

    test "rejects struct observed metadata" do
      observed = %{observed_data() | "metadata" => Record.new("k", %{})}
      assert {:error, :malformed_container} = Core.prepare(observed, governed())
    end

    test "rejects struct governed input" do
      assert {:error, :governed_shape} =
               Core.prepare(observed_data(), Record.new("k", %{}))
    end

    test "rejects struct governed metadata value" do
      governed = %{governed() | "metadata" => Record.new("k", %{})}
      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects struct exact_template_policy value" do
      governed = put_in(governed(), ["metadata", "exact_template_policy"], Record.new("k", %{}))
      assert {:error, :policy_invalid} = Core.prepare(observed_data(), governed)
    end

    test "rejects struct capability item" do
      governed = governed(initial_capabilities: [Record.new("k", %{})])
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), governed)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # prepare/2 — atom/string alias conflicts (atom-only included)
  # ─────────────────────────────────────────────────────────────────────

  describe "prepare/2 atom-alias rejection" do
    test "rejects atom-only governed top-level key in observed" do
      observed = observed_data() |> Map.delete("template") |> Map.put(:template, "atom")
      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed())
    end

    test "rejects atom coexisting with string governed key in observed" do
      observed = observed_data() |> Map.put(:template, "atom")
      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed())
    end

    test "rejects atom alias of initial_capabilities in observed" do
      observed = observed_data() |> Map.put(:initial_capabilities, [])
      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed())
    end

    test "rejects atom alias of metadata in observed" do
      observed = observed_data() |> Map.put(:metadata, %{})
      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed())
    end

    test "rejects atom alias of exact_template_policy in observed metadata" do
      observed =
        observed_data(metadata: Map.put(observed_data()["metadata"], :exact_template_policy, %{}))

      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed())
    end

    test "rejects ANY atom key in governed input" do
      governed = Map.put(governed(), :template, "atom")
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), governed)
    end

    test "rejects atom key in governed metadata" do
      governed = put_in(governed(), ["metadata"], Map.put(governed()["metadata"], :extra, 1))
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), governed)
    end

    test "rejects atom alias of resource in a capability item" do
      item = %{resource: "arbor://fs/read", constraints: %{}}
      governed = governed(initial_capabilities: [item])
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), governed)
    end

    test "rejects atom alias of constraints in a capability item" do
      item = %{"resource" => "arbor://fs/read", constraints: %{}}
      governed = governed(initial_capabilities: [item])
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), governed)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # prepare/2 — closed keyset and value validation
  # ─────────────────────────────────────────────────────────────────────

  describe "prepare/2 keyset and value validation" do
    test "rejects governed missing a key" do
      governed = Map.delete(governed(), "template")
      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects governed with an extra key" do
      governed = Map.put(governed(), "extra", 1)
      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects governed metadata missing exact_template_policy" do
      governed = put_in(governed(), ["metadata"], %{})
      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects governed metadata with an extra key" do
      governed = put_in(governed(), ["metadata"], Map.put(governed()["metadata"], "extra", 1))
      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects nil template (no default)" do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), governed(template: nil))
    end

    test "rejects empty template" do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), governed(template: ""))
    end

    test "rejects non-UTF-8 template" do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), governed(template: <<0xFF, 0xFE>>))
    end

    test "rejects oversized template" do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), governed(template: String.duplicate("a", 257)))
    end

    test "rejects template with null bytes" do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), governed(template: "bad\x00name"))
    end

    test "rejects non-binary template" do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), governed(template: :an_atom))
    end

    test "rejects initial_capabilities that is not a list" do
      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: "nope"))
    end

    test "rejects an improper initial_capabilities list" do
      improper = [%{"resource" => "arbor://x", "constraints" => %{}} | :not_a_list_tail]

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: improper))
    end

    test "rejects capability item missing resource" do
      item = %{"constraints" => %{}}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: [item]))
    end

    test "rejects capability item with non-map constraints" do
      item = %{"resource" => "arbor://x", "constraints" => "nope"}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: [item]))
    end

    test "rejects empty resource" do
      item = %{"resource" => "", "constraints" => %{}}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: [item]))
    end

    test "rejects more than 256 capabilities" do
      caps =
        for i <- 1..257 do
          %{"resource" => "arbor://cap/#{i}", "constraints" => %{}}
        end

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: caps))
    end

    test "rejects oversized resource" do
      item = %{"resource" => String.duplicate("a", 1025), "constraints" => %{}}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: [item]))
    end

    test "rejects non-UTF-8 resource" do
      item = %{"resource" => <<0xFF, 0xFE>>, "constraints" => %{}}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: [item]))
    end

    test "rejects resource with null bytes" do
      item = %{"resource" => "arbor://bad\x00uri", "constraints" => %{}}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: [item]))
    end

    test "rejects capability item with struct constraints" do
      item = %{"resource" => "arbor://x", "constraints" => Record.new("k", %{})}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), governed(initial_capabilities: [item]))
    end

    test "rejects exact_template_policy that is not a map" do
      governed = put_in(governed(), ["metadata", "exact_template_policy"], "scalar")

      assert {:error, :policy_invalid} = Core.prepare(observed_data(), governed)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # prepare/2 — determinism
  # ─────────────────────────────────────────────────────────────────────

  describe "prepare/2 determinism" do
    test "same inputs yield identical intended data" do
      observed = observed_data()
      governed = governed()

      assert Core.prepare(observed, governed) == Core.prepare(observed, governed)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # envelope_stable?/2
  # ─────────────────────────────────────────────────────────────────────

  describe "envelope_stable?/2" do
    test "true when id/key/data/metadata/gen/rev all equal" do
      a = record(%{"x" => 1}, 3, 5, inserted_at: ~U[2026-01-01 00:00:00Z])

      b =
        record(%{"x" => 1}, 3, 5,
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-02-02 00:00:00Z]
        )

      # Differing updated_at does NOT affect stability (timestamps excluded).
      assert Core.envelope_stable?(a, b)
    end

    test "false when data differs (token-preserving tamper)" do
      a = record(%{"x" => 1}, 3, 5)
      b = record(%{"x" => 2}, 3, 5)
      refute Core.envelope_stable?(a, b)
    end

    test "false when id differs" do
      a = record(%{"x" => 1}, 3, 5, id: "rec_a")
      b = record(%{"x" => 1}, 3, 5, id: "rec_b")
      refute Core.envelope_stable?(a, b)
    end

    test "false when metadata differs" do
      a = record(%{"x" => 1}, 3, 5, metadata: %{"m" => 1})
      b = record(%{"x" => 1}, 3, 5, metadata: %{"m" => 2})
      refute Core.envelope_stable?(a, b)
    end

    test "false when generation drifts" do
      a = record(%{"x" => 1}, 3, 5)
      b = record(%{"x" => 1}, 4, 5)
      refute Core.envelope_stable?(a, b)
    end

    test "false when revision drifts" do
      a = record(%{"x" => 1}, 3, 5)
      b = record(%{"x" => 1}, 3, 6)
      refute Core.envelope_stable?(a, b)
    end

    test "false when current is not a Record" do
      a = record(%{"x" => 1}, 3, 5)
      refute Core.envelope_stable?(a, %{key: "x"})
    end

    test "false when observed is not a Record" do
      refute Core.envelope_stable?(%{}, record(%{"x" => 1}, 3, 5))
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # classify/3 — full reobservation matrix
  # ─────────────────────────────────────────────────────────────────────

  describe "classify/3 matrix" do
    setup do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}
      {:ok, anchor: anchor, intended: intended}
    end

    test "not_applied when reobserved equals the anchor", %{anchor: a, intended: i} do
      assert Core.classify(a, i, {:ok, a}) == :not_applied
    end

    test "already_applied when reobserved is the exact successor", %{anchor: a, intended: i} do
      successor =
        record(i, a.generation, a.revision + 1,
          id: a.id,
          key: a.key,
          metadata: a.metadata
        )

      assert Core.classify(a, i, {:ok, successor}) == :already_applied
    end

    test "conflict when generation differs (ABA delete/reinsert)", %{anchor: a, intended: i} do
      # Equal data, new generation (delete/reinsert of the same payload).
      successor = record(i, a.generation + 1, 1, id: a.id, key: a.key, metadata: a.metadata)
      assert Core.classify(a, i, {:ok, successor}) == :conflict
    end

    test "conflict when revision is later than successor", %{anchor: a, intended: i} do
      later =
        record(%{"other" => true}, a.generation, a.revision + 2,
          id: a.id,
          key: a.key,
          metadata: a.metadata
        )

      assert Core.classify(a, i, {:ok, later}) == :conflict
    end

    test "conflict when revision is successor but data diverges", %{anchor: a, intended: i} do
      divergent =
        record(%{"template" => "different"}, a.generation, a.revision + 1,
          id: a.id,
          key: a.key,
          metadata: a.metadata
        )

      assert Core.classify(a, i, {:ok, divergent}) == :conflict
    end

    test "conflict when revision equals anchor but data differs (invariant violation)",
         %{anchor: a, intended: i} do
      divergent = record(%{"x" => 9}, a.generation, a.revision, id: a.id, key: a.key)
      assert Core.classify(a, i, {:ok, divergent}) == :conflict
    end

    test "conflict when id diverges on the successor revision", %{anchor: a, intended: i} do
      divergent =
        record(i, a.generation, a.revision + 1, id: "rec_other", key: a.key, metadata: a.metadata)

      assert Core.classify(a, i, {:ok, divergent}) == :conflict
    end

    test "conflict when metadata diverges on the successor revision", %{anchor: a, intended: i} do
      divergent =
        record(i, a.generation, a.revision + 1,
          id: a.id,
          key: a.key,
          metadata: %{"m" => 1}
        )

      assert Core.classify(a, i, {:ok, divergent}) == :conflict
    end

    test "conflict when merely-equal authority values but different unrelated field",
         %{anchor: a} do
      intended = %{"template" => "new", "metadata" => %{}}

      # Authority fields equal intended, but an unrelated field drifted so the
      # full data map is NOT the exact intended successor.
      successor_data = Map.put(intended, "unrelated", "drifted")

      successor =
        record(successor_data, a.generation, a.revision + 1,
          id: a.id,
          key: a.key,
          metadata: a.metadata
        )

      assert Core.classify(a, intended, {:ok, successor}) == :conflict
    end

    test "conflict when slot is absent", %{anchor: a, intended: i} do
      assert Core.classify(a, i, :not_found) == :conflict
    end

    test "outcome_unknown when reobservation is an error", %{anchor: a, intended: i} do
      assert Core.classify(a, i, {:error, :backend_unavailable}) == :outcome_unknown
    end

    test "outcome_unknown when reobserved is not a Record", %{anchor: a, intended: i} do
      assert Core.classify(a, i, {:ok, %{not: :record}}) == :outcome_unknown
    end

    test "outcome_unknown when reobserved key does not match", %{anchor: a, intended: i} do
      wrong_key = record(i, a.generation, a.revision + 1, id: a.id, key: "other")
      assert Core.classify(a, i, {:ok, wrong_key}) == :outcome_unknown
    end

    test "classify is deterministic", %{anchor: a, intended: i} do
      successor =
        record(i, a.generation, a.revision + 1, id: a.id, key: a.key, metadata: a.metadata)

      assert Core.classify(a, i, {:ok, successor}) ==
               Core.classify(a, i, {:ok, successor})
    end
  end
end
