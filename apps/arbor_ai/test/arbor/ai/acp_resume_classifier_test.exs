defmodule Arbor.AI.AcpResumeClassifierTest do
  use ExUnit.Case, async: true

  alias Arbor.AI

  @moduletag :fast

  test "classifies only structural unsupported load_session and resource-missing shapes" do
    assert AI.classify_resume_unavailability({:unsupported_capability, :load_session}) ==
             :resume_unavailable

    assert AI.classify_resume_unavailability(%{
             "code" => -32_002,
             "message" => "provider-controlled text is not inspected"
           }) == :resume_unavailable
  end

  test "classifies exact FS_NOT_FOUND nested under string-keyed JSON-RPC -32603" do
    # Live Grok shape from task_187330: path gone after workspace rebinding.
    assert AI.classify_resume_unavailability(%{
             "code" => -32_603,
             "data" => %{
               "code" => "FS_NOT_FOUND",
               "detail" => "No such file or directory (os error 2)"
             },
             "message" => "Path not found."
           }) == :resume_unavailable

    # Nested data fields beyond code are ignored; only data.code is structural.
    assert AI.classify_resume_unavailability(%{
             "code" => -32_603,
             "data" => %{"code" => "FS_NOT_FOUND"},
             "message" => "any provider message"
           }) == :resume_unavailable
  end

  test "does not classify timeout, transport, rate-limit, generic -32603, or lookalikes" do
    for reason <- [
          :timeout,
          {:transport_error, :closed},
          {:rate_limit, 1_000},
          %{"code" => -32601, "message" => "load_session is not supported"},
          %{"code" => -32602, "message" => "unknown session"},
          # Generic internal error without nested FS_NOT_FOUND stays fail-closed.
          %{"code" => -32_603, "message" => "Path not found."},
          %{"code" => -32_603, "data" => %{"code" => "OTHER"}},
          %{"code" => -32_603, "data" => "FS_NOT_FOUND"},
          # Message/detail text must never classify.
          %{
            "code" => -32_603,
            "data" => %{"detail" => "FS_NOT_FOUND"},
            "message" => "FS_NOT_FOUND"
          },
          # Atom-keyed maps are not ACP wire errors.
          %{code: -32_002, message: "atom-keyed maps are not ACP wire errors"},
          %{
            code: -32_603,
            data: %{code: "FS_NOT_FOUND"},
            message: "atom-keyed lookalike"
          },
          %{"error" => %{"code" => -32601, "message" => "method not found"}},
          {:unsupported_capability, :create_session},
          {:unsupported_capability, "load_session"}
        ] do
      assert AI.classify_resume_unavailability(reason) == :not_resume_unavailable
    end
  end
end
