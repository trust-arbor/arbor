defmodule Arbor.Contracts.Flow.ItemTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Flow.Item

  @moduletag :fast

  describe "new/1" do
    test "creates item with minimal attrs" do
      assert {:ok, item} = Item.new(title: "Test Item")
      assert item.title == "Test Item"
      assert String.starts_with?(item.id, "item_")
      assert item.acceptance_criteria == []
      assert item.definition_of_done == []
      assert item.depends_on == []
      assert item.blocks == []
      assert item.metadata == %{}
    end

    test "creates item with all fields" do
      criteria = [%{text: "First", completed: false}]
      done = [%{text: "Done item", completed: true}]

      attrs = [
        title: "Full Item",
        id: "item_custom123",
        priority: :high,
        category: :feature,
        summary: "A summary",
        why_it_matters: "Important because",
        acceptance_criteria: criteria,
        definition_of_done: done,
        depends_on: ["item_other"],
        blocks: ["item_blocked"],
        related_files: ["lib/foo.ex"],
        content_hash: "abc123",
        created_at: ~D[2026-02-01],
        path: "/path/to/item.md",
        raw_content: "# Full Item",
        notes: "Some notes",
        metadata: %{key: "value"}
      ]

      assert {:ok, item} = Item.new(attrs)
      assert item.id == "item_custom123"
      assert item.title == "Full Item"
      assert item.priority == :high
      assert item.category == :feature
      assert item.summary == "A summary"
      assert item.why_it_matters == "Important because"
      assert item.acceptance_criteria == criteria
      assert item.definition_of_done == done
      assert item.depends_on == ["item_other"]
      assert item.blocks == ["item_blocked"]
      assert item.related_files == ["lib/foo.ex"]
      assert item.content_hash == "abc123"
      assert item.created_at == ~D[2026-02-01]
      assert item.path == "/path/to/item.md"
      assert item.raw_content == "# Full Item"
      assert item.notes == "Some notes"
      assert item.metadata == %{key: "value"}
    end

    test "requires title" do
      assert_raise KeyError, fn ->
        Item.new([])
      end
    end

    test "rejects empty title" do
      assert {:error, {:invalid_title, ""}} = Item.new(title: "")
    end

    test "validates priority" do
      assert {:ok, _} = Item.new(title: "Test", priority: :critical)
      assert {:ok, _} = Item.new(title: "Test", priority: :high)
      assert {:ok, _} = Item.new(title: "Test", priority: :medium)
      assert {:ok, _} = Item.new(title: "Test", priority: :low)
      assert {:ok, _} = Item.new(title: "Test", priority: :someday)
      assert {:ok, _} = Item.new(title: "Test", priority: nil)
      assert {:error, {:invalid_priority, :invalid}} = Item.new(title: "Test", priority: :invalid)
    end

    test "validates category" do
      assert {:ok, _} = Item.new(title: "Test", category: :feature)
      assert {:ok, _} = Item.new(title: "Test", category: :bug)
      assert {:ok, _} = Item.new(title: "Test", category: :refactor)
      assert {:ok, _} = Item.new(title: "Test", category: :infrastructure)
      assert {:ok, _} = Item.new(title: "Test", category: :idea)
      assert {:ok, _} = Item.new(title: "Test", category: :research)
      assert {:ok, _} = Item.new(title: "Test", category: :documentation)
      assert {:ok, _} = Item.new(title: "Test", category: nil)
      assert {:error, {:invalid_category, :invalid}} = Item.new(title: "Test", category: :invalid)
    end

    test "validates criteria format" do
      valid_criteria = [%{text: "Do something", completed: false}]
      assert {:ok, _} = Item.new(title: "Test", acceptance_criteria: valid_criteria)

      invalid_criteria = [%{text: "Missing completed"}]
      assert {:error, {:invalid_criteria_format, _}} = Item.new(title: "Test", acceptance_criteria: invalid_criteria)
    end
  end

  describe "new!/1" do
    test "returns item on success" do
      item = Item.new!(title: "Test")
      assert item.title == "Test"
    end

    test "raises on validation error" do
      assert_raise ArgumentError, ~r/Invalid item/, fn ->
        Item.new!(title: "", priority: :invalid)
      end
    end
  end

  describe "compute_hash/1" do
    test "computes consistent hash" do
      hash1 = Item.compute_hash("test content")
      hash2 = Item.compute_hash("test content")
      assert hash1 == hash2
      assert String.length(hash1) == 16
    end

    test "different content produces different hash" do
      hash1 = Item.compute_hash("content 1")
      hash2 = Item.compute_hash("content 2")
      refute hash1 == hash2
    end
  end

  describe "content_changed?/2" do
    test "returns true when hash is nil" do
      {:ok, item} = Item.new(title: "Test", content_hash: nil)
      assert Item.content_changed?(item, "new content")
    end

    test "returns true when hash is empty" do
      {:ok, item} = Item.new(title: "Test", content_hash: "")
      assert Item.content_changed?(item, "new content")
    end

    test "returns true when content differs" do
      content = "original content"
      {:ok, item} = Item.new(title: "Test", content_hash: Item.compute_hash(content))
      assert Item.content_changed?(item, "different content")
    end

    test "returns false when content is same" do
      content = "same content"
      {:ok, item} = Item.new(title: "Test", content_hash: Item.compute_hash(content))
      refute Item.content_changed?(item, content)
    end
  end

  describe "all_criteria_completed?/1" do
    test "returns true for empty criteria" do
      {:ok, item} = Item.new(title: "Test")
      assert Item.all_criteria_completed?(item)
    end

    test "returns true when all completed" do
      criteria = [
        %{text: "First", completed: true},
        %{text: "Second", completed: true}
      ]
      {:ok, item} = Item.new(title: "Test", acceptance_criteria: criteria)
      assert Item.all_criteria_completed?(item)
    end

    test "returns false when any incomplete" do
      criteria = [
        %{text: "First", completed: true},
        %{text: "Second", completed: false}
      ]
      {:ok, item} = Item.new(title: "Test", acceptance_criteria: criteria)
      refute Item.all_criteria_completed?(item)
    end
  end

  describe "all_done_completed?/1" do
    test "returns true for empty done list" do
      {:ok, item} = Item.new(title: "Test")
      assert Item.all_done_completed?(item)
    end

    test "returns true when all done" do
      done = [%{text: "Task", completed: true}]
      {:ok, item} = Item.new(title: "Test", definition_of_done: done)
      assert Item.all_done_completed?(item)
    end

    test "returns false when any not done" do
      done = [%{text: "Task", completed: false}]
      {:ok, item} = Item.new(title: "Test", definition_of_done: done)
      refute Item.all_done_completed?(item)
    end
  end

  describe "valid_priorities/0 and valid_priority?/1" do
    test "returns all valid priorities" do
      priorities = Item.valid_priorities()
      assert :critical in priorities
      assert :high in priorities
      assert :medium in priorities
      assert :low in priorities
      assert :someday in priorities
    end

    test "valid_priority? checks correctly" do
      assert Item.valid_priority?(:high)
      refute Item.valid_priority?(:invalid)
    end
  end

  describe "valid_categories/0 and valid_category?/1" do
    test "returns all valid categories" do
      categories = Item.valid_categories()
      assert :feature in categories
      assert :bug in categories
      assert :refactor in categories
    end

    test "valid_category? checks correctly" do
      assert Item.valid_category?(:feature)
      refute Item.valid_category?(:invalid)
    end
  end
end
