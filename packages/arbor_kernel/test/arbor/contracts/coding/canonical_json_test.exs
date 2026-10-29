defmodule Arbor.Contracts.Coding.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.CanonicalJson

  @moduletag :fast

  test "keys are sorted bytewise at every level regardless of map size or insertion order" do
    # Above 32 keys Erlang maps are hash-ordered, so a naive sort-then-rebuild
    # loses the order; the encoder must not depend on map iteration order.
    big =
      for i <- 1..40, into: %{}, do: {"k#{String.pad_leading(Integer.to_string(i), 3, "0")}", i}

    nested = %{"z" => big, "a" => [%{"y" => 1, "x" => 2}, "s"], "m" => %{}}

    reversed =
      nested
      |> Enum.sort_by(fn {k, _} -> k end, :desc)
      |> Map.new()
      |> Map.update!("z", fn m -> m |> Enum.sort_by(fn {k, _} -> k end, :desc) |> Map.new() end)

    assert {:ok, a} = CanonicalJson.encode(nested)
    assert {:ok, b} = CanonicalJson.encode(reversed)
    assert a == b
    assert String.starts_with?(a, ~s({"a":[{"x":2,"y":1},"s"],"m":{},"z":{"k001":1,"k002":2,))
    refute a =~ " "
  end

  test "atom keys encode as their string names, sorted with string keys" do
    assert CanonicalJson.encode(%{"a" => 2, b: 1}) == {:ok, ~s({"a":2,"b":1})}
  end

  test "canonical?/2 accepts only the exact canonical bytes of the decoded value" do
    json = ~s({"a":1,"b":[1,2]})
    assert CanonicalJson.canonical?(json, Jason.decode!(json))
    refute CanonicalJson.canonical?(~s({"b":[1,2],"a":1}), Jason.decode!(json))
    refute CanonicalJson.canonical?(~s({ "a": 1, "b": [1, 2] }), Jason.decode!(json))

    refute CanonicalJson.canonical?(
             ~s({"a":1,"a":1,"b":[1,2]}),
             Jason.decode!(~s({"a":1,"a":1,"b":[1,2]}))
           )

    refute CanonicalJson.canonical?(nil, %{})
  end

  test "non-encodable values are errors, not raises" do
    assert {:error, :not_encodable} = CanonicalJson.encode(%{"f" => fn -> 1 end})
    assert_raise ArgumentError, fn -> CanonicalJson.encode!(%{"f" => fn -> 1 end}) end
  end
end
