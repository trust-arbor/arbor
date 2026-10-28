defmodule Arbor.Persistence.Ecto.EventSerializerTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Ecto.EventSerializer

  test "arbitrary public type hints deserialize to JSON maps instead of structs" do
    encoded = EventSerializer.serialize(%{outer: %{value: 1}})

    assert EventSerializer.deserialize(encoded, type: "arbor.review.ordinary") ==
             %{"outer" => %{"value" => 1}}
  end
end
