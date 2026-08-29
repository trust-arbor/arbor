defmodule Arbor.Gateway.HttpServerOptionsTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.HttpServerOptions

  @moduletag :fast

  test "idle_timeout regression: the HTTP idle timeout always exceeds the MCP handler budget" do
    # Cowboy's 60 s default closed long signed MCP calls mid-request; the
    # signer's :httpc re-sent the body and the gateway rejected the replayed
    # nonce (2026-08-28). The connection must outlive the handler call.
    opts =
      HttpServerOptions.build(port: 4000, ip: {127, 0, 0, 1}, handler_call_timeout_ms: 600_000)

    assert opts[:port] == 4000
    assert opts[:ip] == {127, 0, 0, 1}
    assert opts[:protocol_options][:idle_timeout] > 600_000
    assert HttpServerOptions.idle_timeout(45_000, nil) > 45_000
  end

  test "a configured idle timeout is honoured only when it is larger than the floor" do
    assert HttpServerOptions.idle_timeout(45_000, 900_000) == 900_000

    assert HttpServerOptions.idle_timeout(600_000, 60_000) ==
             HttpServerOptions.idle_timeout(600_000, nil)
  end
end
