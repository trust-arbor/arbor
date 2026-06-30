defmodule Arbor.Trust.AuthorityTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.Authority

  describe "new_profile/1" do
    test "creates profile with default (cautious) preset" do
      profile = Authority.new_profile("agent_123")
      assert profile.agent_id == "agent_123"
      assert profile.baseline == :ask
    end
  end

  describe "effective_mode/3" do
    test "returns baseline for unmatched URI" do
      profile = Authority.apply_preset(Authority.new_profile("agent_123"), :hands_off)
      assert Authority.effective_mode(profile, "arbor://unknown/thing") == :allow
    end

    test "returns specific rule for matched URI" do
      profile = Authority.apply_preset(Authority.new_profile("agent_123"), :hands_off)
      assert Authority.effective_mode(profile, "arbor://shell/exec") == :ask
    end

    test "security ceiling overrides user preference" do
      profile = Authority.apply_preset(Authority.new_profile("agent_123"), :full_trust)
      # full_trust baseline is :auto, but shell ceiling is :ask
      assert Authority.effective_mode(profile, "arbor://shell/exec") == :ask
    end

    test "longest prefix match wins" do
      # Start with a clean profile (no preset rules that might interfere)
      profile =
        %{Authority.new_profile("agent_123") | rules: %{}}
        |> Authority.set_rule("arbor://code", :ask)
        |> Authority.set_rule("arbor://code/read", :auto)

      assert Authority.effective_mode(profile, "arbor://code/read/file.ex") == :auto
      assert Authority.effective_mode(profile, "arbor://code/write/file.ex") == :ask
    end

    test "A1: proactive notify is allowed by default (cautious preset, no ceiling caps it)" do
      {_baseline, rules} = Authority.preset_rules(:cautious)
      # The preset grants notify allow-by-default (vs the :ask baseline).
      assert rules["arbor://comms/notify/session"] == :allow

      profile = %{Authority.new_profile("agent_a1") | rules: rules}
      # No security ceiling on comms/notify, so :allow survives most_restrictive.
      assert Authority.effective_mode(profile, "arbor://comms/notify/session") == :allow
    end
  end

  describe "most_restrictive/1" do
    test "returns most restrictive mode" do
      assert Authority.most_restrictive([:auto, :allow, :ask]) == :ask
      assert Authority.most_restrictive([:auto, :block]) == :block
      assert Authority.most_restrictive([:auto, :auto]) == :auto
    end
  end

  describe "apply_preset/2" do
    test "explicitly resets baseline and merges preset rules" do
      profile = Authority.new_profile("agent_123")
      assert profile.baseline == :ask

      updated = Authority.apply_preset(profile, :hands_off)
      assert updated.baseline == :allow
      assert updated.rules["arbor://shell"] == :ask
    end

    test "preserves user-customized rules across preset application" do
      profile =
        "agent_123"
        |> Authority.new_profile()
        |> then(fn p ->
          # User customization: explicit allow on a URI not in any preset
          %{p | rules: Map.put(p.rules, "arbor://custom/private/api", :auto)}
        end)

      updated = Authority.apply_preset(profile, :hands_off)

      assert updated.rules["arbor://custom/private/api"] == :auto,
             "user customization should survive preset application"
    end
  end

  describe "freeze/unfreeze" do
    test "freeze sets frozen state" do
      profile = Authority.new_profile("agent_123")
      frozen = Authority.freeze(profile, :security_incident)
      assert frozen.frozen == true
      assert frozen.frozen_reason == :security_incident
    end

    test "unfreeze clears frozen state" do
      profile = Authority.new_profile("agent_123") |> Authority.freeze(:test)
      unfrozen = Authority.unfreeze(profile)
      assert unfrozen.frozen == false
      assert unfrozen.frozen_reason == nil
    end
  end

  describe "explain/3" do
    test "returns resolution chain" do
      profile = Authority.apply_preset(Authority.new_profile("agent_123"), :hands_off)
      explanation = Authority.explain(profile, "arbor://shell/exec")

      assert explanation.effective_mode == :ask
      assert explanation.user_mode == :ask
      assert explanation.ceiling_mode == :ask
      assert explanation.baseline == :allow
    end
  end

  describe "show_summary/1" do
    test "formats profile for display" do
      profile = Authority.apply_preset(Authority.new_profile("agent_123"), :hands_off)
      summary = Authority.show_summary(profile)

      assert summary.baseline == :allow
      assert summary.agent_id == "agent_123"
      refute Map.has_key?(summary, :stats)
    end
  end

  describe "for_persistence/1 + from_persistence/1 round-trip" do
    test "round-trips a fresh profile preserving all material fields" do
      original = Authority.new_profile("agent_round_trip")

      serialized = Authority.for_persistence(original)
      assert is_map(serialized)
      # DateTime fields are ISO8601 strings in the serialized form
      assert is_binary(serialized.created_at)
      assert is_binary(serialized.updated_at)

      {:ok, restored} = Authority.from_persistence(serialized)

      assert restored.agent_id == original.agent_id
      assert restored.baseline == original.baseline
      assert restored.rules == original.rules
      assert %DateTime{} = restored.created_at
      assert %DateTime{} = restored.updated_at
    end

    test "round-trips a profile with custom rules" do
      original =
        "agent_custom"
        |> Authority.new_profile()
        |> then(fn p ->
          %{p | rules: Map.put(p.rules, "arbor://custom/api", :auto)}
        end)

      serialized = Authority.for_persistence(original)
      {:ok, restored} = Authority.from_persistence(serialized)

      assert restored.rules["arbor://custom/api"] == :auto
    end

    @tag spec: "TRUST-10"
    test "from_persistence accepts string-keyed maps (e.g. JSONB roundtrip)" do
      original = Authority.new_profile("agent_string_keyed")
      serialized = Authority.for_persistence(original)

      string_keyed =
        for {k, v} <- serialized, into: %{} do
          {to_string(k), v}
        end

      {:ok, restored} = Authority.from_persistence(string_keyed)
      assert restored.agent_id == "agent_string_keyed"
      assert restored.baseline == original.baseline
    end

    @tag spec: "TRUST-4,TRUST-10"
    test "from_persistence coerces invalid rule modes to :ask (safe default)" do
      data = %{
        agent_id: "agent_bad_mode",
        rules: %{"arbor://something" => "garbage_mode"}
      }

      {:ok, profile} = Authority.from_persistence(data)
      assert profile.rules["arbor://something"] == :ask
    end

    test "from_persistence rejects data without an agent_id" do
      assert {:error, :invalid_data} = Authority.from_persistence(%{})
      assert {:error, :invalid_data} = Authority.from_persistence(nil)
    end
  end
end
