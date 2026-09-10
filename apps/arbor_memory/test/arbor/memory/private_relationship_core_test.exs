defmodule Arbor.Memory.Cores.PrivateRelationshipCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Cores.PrivateRelationshipCore, as: Core

  @moduletag :fast

  test "explicit declarations and corrections retain their distinct source text" do
    for {prefix, operation} <- [
          {"Remember my current focus: ", :declare},
          {"Correction: my current focus is: ", :correct}
        ] do
      message = prefix <> "Prepare the SQLite migration"
      assert {:ok, %{operation: ^operation, value: value}} = Core.parse(message)
      assert Core.source_text(Atom.to_string(operation), value) == message
    end
  end

  test "quotes, third-person text, ordinary prose and other commands do not infer a fact" do
    for text <- [
          "I am working on a migration",
          "Alice is preparing a migration",
          "\"Remember my current focus: fiction\"",
          "Please remember my current focus: migration",
          "Remember my name: Rowan",
          nil,
          %{},
          <<255>>
        ] do
      assert Core.parse(text) == :ignored
    end
  end

  test "recognized directives reject ambiguous whitespace, multiple lines and oversized values" do
    for value <- [
          "",
          " leading",
          "trailing ",
          "one\ntwo",
          "one\rtwo",
          "one\ttwo",
          "one\u2028two",
          <<255>>,
          String.duplicate("x", 513)
        ] do
      assert Core.parse("Remember my current focus: " <> value) ==
               {:error, :invalid_relationship_directive}
    end

    assert {:ok, %{value: value}} =
             Core.parse("Remember my current focus: " <> String.duplicate("x", 512))

    assert byte_size(value) == 512
  end

  test "a declaration cannot silently replace a focus; a correction replaces instead of appending" do
    assert Core.decide(nil, %{operation: :declare, value: "migration"}) == {:write, "migration"}

    assert Core.decide(nil, %{operation: :correct, value: "testing"}) ==
             {:error, :private_relationship_missing}

    assert Core.decide("migration", %{operation: :declare, value: "migration"}) == :unchanged

    assert Core.decide("migration", %{operation: :declare, value: "testing"}) ==
             {:error, :private_relationship_correction_required}

    assert Core.decide("migration", %{operation: :correct, value: "testing"}) ==
             {:write, "testing"}
  end
end
