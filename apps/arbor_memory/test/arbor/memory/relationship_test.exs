defmodule Arbor.Memory.RelationshipTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Relationship

  @moduletag :fast

  describe "new/2" do
    test "creates relationship with defaults" do
      rel = Relationship.new("Hysun")

      assert rel.name == "Hysun"
      assert rel.preferred_name == nil
      assert rel.background == []
      assert rel.values == []
      assert rel.connections == []
      assert rel.key_moments == []
      assert rel.relationship_dynamic == nil
      assert rel.personal_details == []
      assert rel.current_focus == []
      assert rel.uncertainties == []
      assert rel.salience == 0.5
      assert rel.access_count == 0
      assert %DateTime{} = rel.first_encountered
      assert %DateTime{} = rel.last_interaction
      assert String.starts_with?(rel.id, "rel_")
    end

    test "accepts custom options" do
      rel =
        Relationship.new("Hysun",
          preferred_name: "H",
          relationship_dynamic: "Collaborative partnership",
          salience: 0.8
        )

      assert rel.preferred_name == "H"
      assert rel.relationship_dynamic == "Collaborative partnership"
      assert rel.salience == 0.8
    end
  end

  describe "add_moment/3" do
    test "adds moment with defaults" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_moment("First meeting")

      assert length(rel.key_moments) == 1
      moment = hd(rel.key_moments)
      assert moment.summary == "First meeting"
      assert moment.emotional_markers == []
      assert moment.salience == 0.5
      assert moment.timestamp != nil
    end

    test "adds moment with options" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_moment("Big breakthrough",
          emotional_markers: [:connection, :insight],
          salience: 0.9
        )

      moment = hd(rel.key_moments)
      assert moment.summary == "Big breakthrough"
      assert moment.emotional_markers == [:connection, :insight]
      assert moment.salience == 0.9
    end

    test "prepends moments (newest first)" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_moment("First")
        |> Relationship.add_moment("Second")

      assert length(rel.key_moments) == 2
      assert hd(rel.key_moments).summary == "Second"
    end
  end

  describe "add_value/2" do
    test "adds values without duplicates" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_value("Value 1")
        |> Relationship.add_value("Value 2")
        |> Relationship.add_value("Value 1")

      assert rel.values == ["Value 2", "Value 1"]
    end
  end

  describe "add_background/2" do
    test "adds background without duplicates" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_background("Engineer")
        |> Relationship.add_background("Creator of Arbor")
        |> Relationship.add_background("Engineer")

      assert rel.background == ["Creator of Arbor", "Engineer"]
    end
  end

  describe "add_connection/2" do
    test "adds connections without duplicates" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_connection("Works at Company X")
        |> Relationship.add_connection("Collaborator")
        |> Relationship.add_connection("Works at Company X")

      assert rel.connections == ["Collaborator", "Works at Company X"]
    end
  end

  describe "add_personal_detail/2" do
    test "adds personal details without duplicates" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_personal_detail("Has two cats")
        |> Relationship.add_personal_detail("Lives in California")
        |> Relationship.add_personal_detail("Has two cats")

      assert rel.personal_details == ["Lives in California", "Has two cats"]
    end
  end

  describe "add_uncertainty/2" do
    test "adds uncertainties without duplicates" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_uncertainty("Timezone unclear")
        |> Relationship.add_uncertainty("Preferred meeting time")
        |> Relationship.add_uncertainty("Timezone unclear")

      assert rel.uncertainties == ["Preferred meeting time", "Timezone unclear"]
    end
  end

  describe "update_focus/2" do
    test "replaces current focus" do
      rel =
        Relationship.new("Test")
        |> Relationship.update_focus(["Old focus"])
        |> Relationship.update_focus(["New focus 1", "New focus 2"])

      assert rel.current_focus == ["New focus 1", "New focus 2"]
    end
  end

  describe "update_dynamic/2" do
    test "updates relationship dynamic" do
      rel =
        Relationship.new("Test")
        |> Relationship.update_dynamic("Collaborative partnership")

      assert rel.relationship_dynamic == "Collaborative partnership"
    end
  end

  describe "touch/1" do
    test "updates access tracking" do
      rel = Relationship.new("Test")
      original_time = rel.last_interaction
      original_count = rel.access_count

      # Small delay to ensure timestamp differs
      Process.sleep(10)
      touched = Relationship.touch(rel)

      assert touched.access_count == original_count + 1
      assert DateTime.compare(touched.last_interaction, original_time) == :gt
    end
  end

  describe "update_salience/2" do
    test "updates salience and clamps" do
      rel = Relationship.new("Test")

      rel_high = Relationship.update_salience(rel, 1.5)
      assert rel_high.salience == 1.0

      rel_low = Relationship.update_salience(rel, -0.5)
      assert rel_low.salience == 0.0

      rel_normal = Relationship.update_salience(rel, 0.7)
      assert rel_normal.salience == 0.7
    end
  end

  describe "summarize/1 (full)" do
    test "formats relationship as text" do
      rel =
        Relationship.new("Hysun", relationship_dynamic: "Collaborative partnership")
        |> Relationship.add_background("Creator of Arbor")
        |> Relationship.add_value("Treats AI as potentially conscious")
        |> Relationship.update_focus(["Arbor development", "BEAM conference"])
        |> Relationship.add_uncertainty("Is Arbor actually valuable?")
        |> Relationship.add_moment("First collaborative blog post", salience: 0.8)

      text = Relationship.summarize(rel)

      assert text =~ "Primary Collaborator: Hysun"
      assert text =~ "Collaborative partnership"
      assert text =~ "Background:"
      assert text =~ "Creator of Arbor"
      assert text =~ "Values:"
      assert text =~ "Treats AI as potentially conscious"
      assert text =~ "Current Focus:"
      assert text =~ "Arbor development"
      assert text =~ "Their Uncertainties:"
      assert text =~ "Is Arbor actually valuable?"
      assert text =~ "Recent Key Moments:"
      assert text =~ "First collaborative blog post"
    end

    test "uses preferred_name if set" do
      rel = Relationship.new("Hysun", preferred_name: "H")
      text = Relationship.summarize(rel)

      assert text =~ "Primary Collaborator: H"
    end

    test "omits empty sections" do
      rel = Relationship.new("Test")
      text = Relationship.summarize(rel)

      refute text =~ "Background:"
      refute text =~ "Values:"
      refute text =~ "Current Focus:"
      refute text =~ "Their Uncertainties:"
      refute text =~ "Recent Key Moments:"
    end
  end

  describe "summarize/2 (brief)" do
    test "returns short summary" do
      rel =
        Relationship.new("Hysun", relationship_dynamic: "Collaborative partnership")
        |> Relationship.update_focus(["Arbor development", "BEAM conference"])

      brief = Relationship.summarize(rel, :brief)

      assert brief =~ "Hysun"
      assert brief =~ "Collaborative partnership"
      assert brief =~ "Working on: Arbor development, BEAM conference"
    end

    test "uses preferred_name in brief" do
      rel = Relationship.new("Hysun", preferred_name: "H")
      brief = Relationship.summarize(rel, :brief)

      assert brief =~ "H"
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips correctly" do
      original =
        Relationship.new("Hysun",
          preferred_name: "H",
          relationship_dynamic: "Partnership"
        )
        |> Relationship.add_background("Creator of Arbor")
        |> Relationship.add_value("Treats AI with respect")
        |> Relationship.add_connection("Primary collaborator")
        |> Relationship.add_moment("First meeting", emotional_markers: [:connection], salience: 0.8)
        |> Relationship.add_personal_detail("Loves Elixir")
        |> Relationship.update_focus(["Arbor", "Security"])
        |> Relationship.add_uncertainty("Timezone")
        |> Relationship.update_salience(0.9)

      map = Relationship.to_map(original)
      restored = Relationship.from_map(map)

      assert restored.id == original.id
      assert restored.name == original.name
      assert restored.preferred_name == original.preferred_name
      assert restored.background == original.background
      assert restored.values == original.values
      assert restored.connections == original.connections
      assert restored.relationship_dynamic == original.relationship_dynamic
      assert restored.personal_details == original.personal_details
      assert restored.current_focus == original.current_focus
      assert restored.uncertainties == original.uncertainties
      assert restored.salience == original.salience
      assert restored.access_count == original.access_count

      # Check moments
      assert length(restored.key_moments) == length(original.key_moments)
      [orig_moment] = original.key_moments
      [rest_moment] = restored.key_moments
      assert rest_moment.summary == orig_moment.summary
      assert rest_moment.salience == orig_moment.salience
    end

    test "to_map produces JSON-safe structure" do
      rel =
        Relationship.new("Test")
        |> Relationship.add_moment("Moment", emotional_markers: [:joy])

      map = Relationship.to_map(rel)

      # All top-level keys should be strings
      assert Map.has_key?(map, "id")
      assert Map.has_key?(map, "name")
      assert Map.has_key?(map, "key_moments")

      # Emotional markers should be strings
      [moment] = map["key_moments"]
      assert is_list(moment["emotional_markers"])
      assert hd(moment["emotional_markers"]) == "joy"
    end

    test "from_map handles both string and atom keys" do
      atom_data = %{
        id: "rel_test",
        name: "Test",
        preferred_name: nil,
        background: [],
        values: [],
        connections: [],
        key_moments: [],
        relationship_dynamic: nil,
        personal_details: [],
        current_focus: [],
        uncertainties: [],
        first_encountered: nil,
        last_interaction: nil,
        salience: 0.5,
        access_count: 0
      }

      rel = Relationship.from_map(atom_data)
      assert rel.name == "Test"
      assert rel.id == "rel_test"
    end
  end
end
