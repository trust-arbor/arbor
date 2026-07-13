defmodule Arbor.AI.AcpResumeClassifierTest do
  use ExUnit.Case, async: true

  alias Arbor.AI

  @moduletag :fast

  test "classifies only the structural unsupported load_session capability" do
    assert AI.classify_resume_unavailability({:unsupported_capability, :load_session}) ==
             :resume_unavailable

    assert AI.classify_resume_unavailability(%{
             "code" => -32_002,
             "message" => "provider-controlled text is not inspected"
           }) == :resume_unavailable
  end

  test "does not classify timeout, transport, rate-limit, or arbitrary JSON-RPC errors" do
    for reason <- [
          :timeout,
          {:transport_error, :closed},
          {:rate_limit, 1_000},
          %{"code" => -32601, "message" => "load_session is not supported"},
          %{"code" => -32602, "message" => "unknown session"},
          %{code: -32_002, message: "atom-keyed maps are not ACP wire errors"},
          %{"error" => %{"code" => -32601, "message" => "method not found"}},
          {:unsupported_capability, :create_session},
          {:unsupported_capability, "load_session"}
        ] do
      assert AI.classify_resume_unavailability(reason) == :not_resume_unavailable
    end
  end
end
