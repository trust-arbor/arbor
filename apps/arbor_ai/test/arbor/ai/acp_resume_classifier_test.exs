defmodule Arbor.AI.AcpResumeClassifierTest do
  use ExUnit.Case, async: true

  alias Arbor.AI

  @moduletag :fast

  test "classifies only the structural unsupported load_session capability" do
    assert AI.classify_resume_unavailability({:unsupported_capability, :load_session}) ==
             :resume_unavailable
  end

  test "does not classify timeout, transport, rate-limit, or arbitrary JSON-RPC errors" do
    for reason <- [
          :timeout,
          {:transport_error, :closed},
          {:rate_limit, 1_000},
          %{"code" => -32601, "message" => "load_session is not supported"},
          %{"error" => %{"code" => -32601, "message" => "method not found"}},
          {:unsupported_capability, :create_session},
          {:unsupported_capability, "load_session"}
        ] do
      assert AI.classify_resume_unavailability(reason) == :not_resume_unavailable
    end
  end
end
