defmodule Arbor.Client.GatewayOriginTest do
  use ExUnit.Case, async: true
  alias Arbor.Client

  test "public endpoint facade preserves signed and human destination policy without credentials" do
    assert {:ok, "https://example.test:444"} =
             Client.gateway_origin("wss://example.test:444/api/chat/socket")

    assert {:ok, "http://127.0.0.1:4000"} = Client.gateway_origin("http://127.0.0.1:4000/")

    assert {:ok, "http://localhost:4000"} =
             Client.gateway_origin("http://localhost:4000", :signed)

    assert {:error, :unsafe_gateway_url} =
             Client.gateway_origin("http://localhost:4000", :session)

    for url <- [
          nil,
          <<255>>,
          String.duplicate("x", 2_049),
          "http://example.test",
          "https://name:private@example.test",
          "https://example.test?credential=private",
          "https://example.test#private",
          "https://example.test/wrong",
          "https://example.test\n"
        ] do
      assert {:error, :unsafe_gateway_url} = Client.gateway_origin(url, :session)
      assert {:error, :unsafe_gateway_url} = Client.gateway_origin(url, :signed)
    end

    assert {:error, :unsafe_gateway_url} = Client.gateway_origin("https://example.test", :unknown)
  end
end
