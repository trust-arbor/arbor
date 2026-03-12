defmodule Arbor.Common.CapabilityIndexTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.CapabilityIndex
  alias Arbor.Contracts.{CapabilityDescriptor, CapabilityMatch}

  @moduletag :fast

  # Helper to build descriptors quickly
  defp make_descriptor(attrs) do
    defaults = %{
      id: "test:#{:erlang.unique_integer([:positive])}",
      name: "Test Capability",
      kind: :action,
      description: "A test capability",
      tags: [],
      trust_required: :new,
      provider: __MODULE__,
      source_ref: nil,
      metadata: %{}
    }

    struct!(CapabilityDescriptor, Map.merge(defaults, attrs))
  end

  setup do
    # Start a fresh index for each test
    start_supervised!({CapabilityIndex, []})
    :ok
  end

  describe "index/1 and get/1" do
    test "indexes and retrieves a descriptor by ID" do
      descriptor = make_descriptor(%{id: "action:file.read", name: "File Read"})
      assert :ok = CapabilityIndex.index(descriptor)
      assert {:ok, ^descriptor} = CapabilityIndex.get("action:file.read")
    end

    test "returns error for non-existent ID" do
      assert {:error, :not_found} = CapabilityIndex.get("nonexistent")
    end

    test "overwrites existing descriptor on re-index" do
      d1 = make_descriptor(%{id: "action:test", name: "Version 1"})
      d2 = make_descriptor(%{id: "action:test", name: "Version 2"})

      :ok = CapabilityIndex.index(d1)
      :ok = CapabilityIndex.index(d2)

      assert {:ok, result} = CapabilityIndex.get("action:test")
      assert result.name == "Version 2"
    end

    test "count reflects indexed items" do
      assert CapabilityIndex.count() == 0

      :ok = CapabilityIndex.index(make_descriptor(%{id: "a"}))
      assert CapabilityIndex.count() == 1

      :ok = CapabilityIndex.index(make_descriptor(%{id: "b"}))
      assert CapabilityIndex.count() == 2
    end
  end

  describe "remove/1" do
    test "removes an indexed descriptor" do
      descriptor = make_descriptor(%{id: "action:remove.me"})
      :ok = CapabilityIndex.index(descriptor)
      assert {:ok, _} = CapabilityIndex.get("action:remove.me")

      :ok = CapabilityIndex.remove("action:remove.me")
      assert {:error, :not_found} = CapabilityIndex.get("action:remove.me")
    end

    test "removing non-existent ID is a no-op" do
      assert :ok = CapabilityIndex.remove("nonexistent")
    end

    test "count decreases after removal" do
      :ok = CapabilityIndex.index(make_descriptor(%{id: "a"}))
      :ok = CapabilityIndex.index(make_descriptor(%{id: "b"}))
      assert CapabilityIndex.count() == 2

      :ok = CapabilityIndex.remove("a")
      assert CapabilityIndex.count() == 1
    end
  end

  describe "search/2 — keyword matching" do
    test "finds capabilities by name token" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "action:file.read", name: "File Read", description: "Read files"})
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "action:file.write",
            name: "File Write",
            description: "Write files"
          })
        )

      results = CapabilityIndex.search("file")
      assert length(results) == 2
      assert Enum.all?(results, fn %CapabilityMatch{} -> true end)
    end

    test "scores exact name match higher" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "action:email",
            name: "Email Triage",
            description: "Triage emails"
          })
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "skill:email.send",
            name: "Send Email",
            description: "Send an email message"
          })
        )

      results = CapabilityIndex.search("email triage")
      assert length(results) > 0
      first = hd(results)
      assert first.descriptor.id == "action:email"
    end

    test "returns empty for empty query" do
      :ok = CapabilityIndex.index(make_descriptor(%{id: "a", name: "Something"}))
      assert [] = CapabilityIndex.search("")
    end

    test "returns empty for no matches" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "a", name: "File Read", description: "Read files"})
        )

      assert [] = CapabilityIndex.search("quantum entanglement")
    end

    test "matches against tags" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "action:deploy",
            name: "Deploy",
            description: "Deploy app",
            tags: ["infrastructure", "devops"]
          })
        )

      results = CapabilityIndex.search("devops")
      assert length(results) == 1
      assert hd(results).descriptor.id == "action:deploy"
    end

    test "respects limit option" do
      for i <- 1..20 do
        :ok =
          CapabilityIndex.index(
            make_descriptor(%{
              id: "action:file.op#{i}",
              name: "File Operation #{i}",
              description: "File operation"
            })
          )
      end

      assert length(CapabilityIndex.search("file", limit: 5)) == 5
      assert length(CapabilityIndex.search("file", limit: 3)) == 3
    end

    test "default limit is 10" do
      for i <- 1..15 do
        :ok =
          CapabilityIndex.index(
            make_descriptor(%{
              id: "action:op#{i}",
              name: "Operation #{i}",
              description: "An operation"
            })
          )
      end

      assert length(CapabilityIndex.search("operation")) == 10
    end

    test "filters by kind" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "action:read", name: "Read", kind: :action})
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "skill:read", name: "Read Skill", kind: :skill})
        )

      action_results = CapabilityIndex.search("read", kind: :action)
      assert length(action_results) == 1
      assert hd(action_results).descriptor.kind == :action

      skill_results = CapabilityIndex.search("read", kind: :skill)
      assert length(skill_results) == 1
      assert hd(skill_results).descriptor.kind == :skill
    end
  end

  describe "search/2 — trust filtering" do
    setup do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "public",
            name: "Public Tool",
            description: "Public tool",
            trust_required: :new
          })
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "trusted",
            name: "Trusted Tool",
            description: "Trusted tool",
            trust_required: :trusted
          })
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "system",
            name: "System Tool",
            description: "System tool",
            trust_required: :system
          })
        )

      :ok
    end

    test "no trust filter returns all matching" do
      results = CapabilityIndex.search("tool")
      assert length(results) == 3
    end

    test "new tier only sees new-trust capabilities" do
      results = CapabilityIndex.search("tool", trust_tier: :new)
      assert length(results) == 1
      assert hd(results).descriptor.id == "public"
    end

    test "trusted tier sees new through trusted" do
      results = CapabilityIndex.search("tool", trust_tier: :trusted)
      ids = Enum.map(results, & &1.descriptor.id) |> Enum.sort()
      assert ids == ["public", "trusted"]
    end

    test "system tier sees everything" do
      results = CapabilityIndex.search("tool", trust_tier: :system)
      assert length(results) == 3
    end

    test "provisional tier sees only new" do
      results = CapabilityIndex.search("tool", trust_tier: :provisional)
      assert length(results) == 1
      assert hd(results).descriptor.id == "public"
    end
  end

  describe "list/1" do
    test "returns all descriptors" do
      :ok = CapabilityIndex.index(make_descriptor(%{id: "a", name: "A"}))
      :ok = CapabilityIndex.index(make_descriptor(%{id: "b", name: "B"}))

      results = CapabilityIndex.list()
      assert length(results) == 2
      assert Enum.all?(results, &match?(%CapabilityDescriptor{}, &1))
    end

    test "filters by trust tier" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "a", name: "A", trust_required: :new})
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "b", name: "B", trust_required: :trusted})
        )

      assert length(CapabilityIndex.list(trust_tier: :new)) == 1
      assert length(CapabilityIndex.list(trust_tier: :trusted)) == 2
    end

    test "filters by kind" do
      :ok =
        CapabilityIndex.index(make_descriptor(%{id: "a", name: "A", kind: :action}))

      :ok =
        CapabilityIndex.index(make_descriptor(%{id: "b", name: "B", kind: :skill}))

      assert length(CapabilityIndex.list(kind: :action)) == 1
      assert length(CapabilityIndex.list(kind: :skill)) == 1
    end

    test "filters by provider" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "a", name: "A", provider: MyProvider})
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "b", name: "B", provider: OtherProvider})
        )

      assert length(CapabilityIndex.list(provider: MyProvider)) == 1
      assert length(CapabilityIndex.list(provider: OtherProvider)) == 1
    end

    test "empty index returns empty list" do
      assert CapabilityIndex.list() == []
    end
  end

  describe "sync_provider/2" do
    defmodule TestProvider do
      @behaviour Arbor.Contracts.CapabilityProvider

      @impl true
      def list_capabilities(_opts) do
        [
          %CapabilityDescriptor{
            id: "test:one",
            name: "Test One",
            kind: :action,
            provider: __MODULE__
          },
          %CapabilityDescriptor{
            id: "test:two",
            name: "Test Two",
            kind: :skill,
            provider: __MODULE__
          }
        ]
      end

      @impl true
      def describe("test:one") do
        {:ok,
         %CapabilityDescriptor{
           id: "test:one",
           name: "Test One",
           kind: :action,
           provider: __MODULE__
         }}
      end

      def describe(_), do: {:error, :not_found}

      @impl true
      def execute(_id, _input, _opts), do: {:ok, :executed}
    end

    defmodule FailingProvider do
      @behaviour Arbor.Contracts.CapabilityProvider

      @impl true
      def list_capabilities(_opts), do: raise("boom")

      @impl true
      def describe(_), do: {:error, :not_found}

      @impl true
      def execute(_id, _input, _opts), do: {:error, :not_implemented}
    end

    test "syncs all capabilities from a provider" do
      assert {:ok, 2} = CapabilityIndex.sync_provider(TestProvider)
      assert CapabilityIndex.count() == 2
      assert {:ok, %{name: "Test One"}} = CapabilityIndex.get("test:one")
      assert {:ok, %{name: "Test Two"}} = CapabilityIndex.get("test:two")
    end

    test "handles provider errors gracefully" do
      assert {:ok, 0} = CapabilityIndex.sync_provider(FailingProvider)
      assert CapabilityIndex.count() == 0
    end
  end

  describe "boot sync" do
    test "syncs providers passed at startup" do
      # Stop the default one from setup
      stop_supervised!(CapabilityIndex)

      start_supervised!(
        {CapabilityIndex,
         [
           providers: [
             Arbor.Common.CapabilityIndexTest.TestProvider
           ]
         ]}
      )

      assert CapabilityIndex.count() == 2
    end
  end

  describe "score ordering" do
    test "results are sorted by descending score" do
      # "file read" should score higher for query "file read" than "file write"
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "action:file.write",
            name: "File Write",
            description: "Write data to files"
          })
        )

      :ok =
        CapabilityIndex.index(
          make_descriptor(%{
            id: "action:file.read",
            name: "File Read",
            description: "Read data from files"
          })
        )

      results = CapabilityIndex.search("file read")
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "all match results have tier 1" do
      :ok =
        CapabilityIndex.index(
          make_descriptor(%{id: "a", name: "Test", description: "test"})
        )

      results = CapabilityIndex.search("test")
      assert Enum.all?(results, &(&1.tier == 1))
    end
  end
end
