defmodule Arbor.Orchestrator.Graph.EdgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph.Edge

  describe "from_attrs/3" do
    test "populates all typed fields from attrs map" do
      attrs = %{
        "condition" => "outcome == success",
        "label" => "on success",
        "weight" => "10",
        "fidelity" => "compact",
        "thread_id" => "main",
        "loop_restart" => "true"
      }

      edge = Edge.from_attrs("a", "b", attrs)

      assert edge.from == "a"
      assert edge.to == "b"
      assert edge.condition == "outcome == success"
      assert edge.label == "on success"
      assert edge.weight == 10
      assert edge.fidelity == "compact"
      assert edge.thread_id == "main"
      assert edge.loop_restart == true
    end

    test "defaults to nil/false for missing attrs" do
      edge = Edge.from_attrs("a", "b", %{})

      assert edge.condition == nil
      assert edge.label == nil
      assert edge.weight == nil
      assert edge.fidelity == nil
      assert edge.thread_id == nil
      assert edge.loop_restart == false
    end

    test "coerces loop_restart from truthy values" do
      assert Edge.from_attrs("a", "b", %{"loop_restart" => true}).loop_restart == true
      assert Edge.from_attrs("a", "b", %{"loop_restart" => "true"}).loop_restart == true
      assert Edge.from_attrs("a", "b", %{"loop_restart" => 1}).loop_restart == true
      assert Edge.from_attrs("a", "b", %{"loop_restart" => "false"}).loop_restart == false
      assert Edge.from_attrs("a", "b", %{"loop_restart" => false}).loop_restart == false
    end

    test "parses weight as integer" do
      assert Edge.from_attrs("a", "b", %{"weight" => "5"}).weight == 5
      assert Edge.from_attrs("a", "b", %{"weight" => 3}).weight == 3
      assert Edge.from_attrs("a", "b", %{"weight" => "abc"}).weight == nil
    end
  end

  describe "known_attrs/0" do
    test "returns a list of strings" do
      attrs = Edge.known_attrs()
      assert is_list(attrs)
      assert Enum.all?(attrs, &is_binary/1)
    end

    test "includes loop_restart" do
      assert "loop_restart" in Edge.known_attrs()
    end
  end

  describe "attr/3" do
    test "reads from attrs map" do
      edge = Edge.from_attrs("a", "b", %{"custom" => "value"})
      assert Edge.attr(edge, "custom") == "value"
    end

    test "returns default for missing key" do
      edge = Edge.from_attrs("a", "b", %{})
      assert Edge.attr(edge, "missing", "default") == "default"
    end
  end
end
