defmodule Arbor.LLM.OAuth.JwtPayloadTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.OAuth.JwtPayload

  defp fake_jwt(payload) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
    body = Base.url_encode64(Jason.encode!(payload), padding: false)
    "#{header}.#{body}.sig"
  end

  test "decodes a well-formed compact JWT payload" do
    token = fake_jwt(%{"exp" => 123, "sub" => "user-1"})

    assert {:ok, %{"exp" => 123, "sub" => "user-1"}} = JwtPayload.decode(token)
  end

  test "rejects tokens that aren't exactly header.payload.signature" do
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode("only-one-part")
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode("a.b.c.d")
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode("")
  end

  test "rejects a payload segment that isn't valid base64url" do
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode("h.not!!valid!!base64.s")
  end

  test "rejects a payload that decodes to non-JSON or a non-object" do
    non_json = Base.url_encode64("not json", padding: false)
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode("h.#{non_json}.s")

    json_array = Base.url_encode64(Jason.encode!([1, 2, 3]), padding: false)
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode("h.#{json_array}.s")
  end

  test "rejects non-binary input without raising" do
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode(nil)
    assert {:error, :invalid_jwt_payload} = JwtPayload.decode(%{})
  end
end
