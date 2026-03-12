defmodule Arbor.Common.CapabilityResolverTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.{CapabilityIndex, CapabilityResolver}
  alias Arbor.Contracts.{CapabilityDescriptor, CapabilityMatch}

  @moduletag :fast

  defmodule TestProvider do
    @behaviour Arbor.Contracts.CapabilityProvider

    @impl true
    def list_capabilities(_opts), do: []

    @impl true
    def describe(_id), do: {:error, :not_found}

    @impl true
    def execute("action:test.greet", input, _opts) do
      {:ok, "Hello, #{Map.get(input, :name, "world")}!"}
    end

    def execute("action:test.fail", _input, _opts) do
      {:error, :intentional_failure}
    end

    def execute(_, _, _), do: {:error, :not_found}
  end

  defp make_descriptor(attrs) do
    defaults = %{
      id: "test:#{:erlang.unique_integer([:positive])}",
      name: "Test",
      kind: :action,
      description: "",
      tags: [],
      trust_required: :new,
      provider: TestProvider,
      source_ref: nil,
      metadata: %{}
    }

    struct!(CapabilityDescriptor, Map.merge(defaults, attrs))
  end

  setup do
    start_supervised!({CapabilityIndex, []})

    # Index test capabilities
    :ok =
      CapabilityIndex.index(
        make_descriptor(%{
          id: "action:test.greet",
          name: "Greet User",
          description: "Greet a user by name",
          tags: ["greeting", "social"],
          trust_required: :new
        })
      )

    :ok =
      CapabilityIndex.index(
        make_descriptor(%{
          id: "action:test.fail",
          name: "Failing Action",
          description: "An action that always fails",
          tags: ["test"],
          trust_required: :new
        })
      )

    :ok =
      CapabilityIndex.index(
        make_descriptor(%{
          id: "skill:email-triage",
          name: "Email Triage",
          description: "Triage and prioritize emails by urgency",
          tags: ["email", "productivity", "triage"],
          kind: :skill,
          trust_required: :established
        })
      )

    :ok =
      CapabilityIndex.index(
        make_descriptor(%{
          id: "pipeline:consensus-flow",
          name: "Consensus Flow",
          description: "Run council consensus decision process",
          tags: ["consensus", "council", "decision"],
          kind: :pipeline,
          trust_required: :trusted
        })
      )

    :ok
  end

  describe "search/2" do
    test "returns matching capabilities" do
      results = CapabilityResolver.search("greet")
      assert length(results) > 0
      assert Enum.all?(results, &match?(%CapabilityMatch{}, &1))
    end

    test "returns empty for no matches" do
      assert [] = CapabilityResolver.search("quantum entanglement teleporter")
    end

    test "respects limit option" do
      results = CapabilityResolver.search("test", limit: 1)
      assert length(results) <= 1
    end

    test "filters by trust tier" do
      # New tier should only see :new trust capabilities
      results = CapabilityResolver.search("email triage", trust_tier: :new)
      assert Enum.all?(results, fn %{descriptor: d} -> d.trust_required == :new end)
    end

    test "higher trust tier sees more capabilities" do
      new_results = CapabilityResolver.search("triage email consensus", trust_tier: :new)
      system_results = CapabilityResolver.search("triage email consensus", trust_tier: :system)
      assert length(system_results) >= length(new_results)
    end

    test "forced tier 1 only uses keyword search" do
      results = CapabilityResolver.search("greet", tier: 1)
      assert Enum.all?(results, fn %{tier: t} -> t == 1 end)
    end

    test "filters by kind" do
      results = CapabilityResolver.search("email", kind: :skill)
      assert Enum.all?(results, fn %{descriptor: d} -> d.kind == :skill end)
    end

    test "results sorted by score descending" do
      results = CapabilityResolver.search("greet user")
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "best_match/2" do
    test "returns best match" do
      assert {:ok, %CapabilityMatch{} = match} = CapabilityResolver.best_match("greet user")
      assert match.descriptor.id == "action:test.greet"
    end

    test "returns error when no match" do
      assert {:error, :no_match} = CapabilityResolver.best_match("zzzzz nonexistent qqqqq")
    end

    test "respects trust tier" do
      # Email triage requires :established, so :new tier shouldn't find it
      assert {:error, :no_match} =
               CapabilityResolver.best_match("email triage",
                 trust_tier: :new,
                 kind: :skill
               )

      assert {:ok, match} =
               CapabilityResolver.best_match("email triage",
                 trust_tier: :established,
                 kind: :skill
               )

      assert match.descriptor.id == "skill:email-triage"
    end
  end

  describe "resolve_and_execute/3" do
    test "finds and executes a capability" do
      assert {:ok, "Hello, Hysun!"} =
               CapabilityResolver.resolve_and_execute("greet user", %{name: "Hysun"})
    end

    test "returns error when no match found" do
      assert {:error, :no_match} =
               CapabilityResolver.resolve_and_execute("nonexistent capability xyz", %{})
    end

    test "returns low_confidence when score below min_score" do
      # "test" is a partial match with low score, min_score 0.99 should reject it
      result =
        CapabilityResolver.resolve_and_execute("test action thing", %{}, min_score: 0.99)

      assert result in [{:error, :no_match}, {:error, :low_confidence}]
    end

    test "propagates execution errors" do
      assert {:error, :intentional_failure} =
               CapabilityResolver.resolve_and_execute("failing action", %{})
    end
  end

  describe "execute/3" do
    test "executes a capability directly by descriptor" do
      descriptor =
        make_descriptor(%{
          id: "action:test.greet",
          name: "Greet",
          provider: TestProvider
        })

      assert {:ok, "Hello, world!"} = CapabilityResolver.execute(descriptor, %{})
    end

    test "returns error for unavailable provider" do
      descriptor =
        make_descriptor(%{
          id: "test:x",
          name: "X",
          provider: NonExistentModule
        })

      assert {:error, {:provider_unavailable, NonExistentModule}} =
               CapabilityResolver.execute(descriptor, %{})
    end
  end

  describe "tiered resolution" do
    test "tier 1 results have tier: 1" do
      results = CapabilityResolver.search("greet", tier: 1)

      for result <- results do
        assert result.tier == 1
      end
    end

    test "high-confidence tier 1 result skips tier 2" do
      # "greet user" should be a strong match with boost, staying in tier 1
      results = CapabilityResolver.search("greet user")

      # All should be tier 1 if scores are high enough
      if hd(results).score >= CapabilityResolver.tier1_threshold() do
        assert Enum.all?(results, fn r -> r.tier == 1 end)
      end
    end
  end
end
