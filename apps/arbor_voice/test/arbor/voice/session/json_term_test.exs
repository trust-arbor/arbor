defmodule Arbor.Voice.Session.JsonTermTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.Session.JsonTerm

  @tag spec: "VOICE-8"
  test "accepts strict JSON terms and rejects atoms, structs, deep, broad, bad UTF-8" do
    assert :ok = JsonTerm.validate(nil)
    assert :ok = JsonTerm.validate(true)
    assert :ok = JsonTerm.validate(1)
    assert :ok = JsonTerm.validate(1.5)
    assert :ok = JsonTerm.validate("ok")
    assert :ok = JsonTerm.validate([1, "a", %{"k" => true}])
    assert :ok = JsonTerm.validate(%{})

    assert :error = JsonTerm.validate(:atom)
    assert :error = JsonTerm.validate(%URI{})
    assert :error = JsonTerm.validate(%{atom_key: 1})
    assert :error = JsonTerm.validate(self())
    assert :error = JsonTerm.validate(<<0xFF, 0xFE>>)

    deep =
      Enum.reduce(1..(JsonTerm.max_depth() + 2), 1, fn _, acc ->
        %{"n" => acc}
      end)

    assert :error = JsonTerm.validate(deep)

    broad = Enum.to_list(1..(JsonTerm.max_nodes() + 5))
    assert :error = JsonTerm.validate(broad)

    huge = String.duplicate("x", JsonTerm.max_encoded_bytes() + 1)
    assert :error = JsonTerm.validate(huge)
  end
end
