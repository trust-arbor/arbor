defmodule Arbor.Gateway.MCP.CallOutcomeTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Tool.CallFailure
  alias Arbor.Gateway.MCP.CallOutcome

  @moduletag :fast

  describe "classify/1 over ExMCP 1.3 error shapes (format: :map)" do
    test "a request that never left is :not_sent" do
      for reason <- [
            :not_connected,
            %ExMCP.Error.ValidationError{field: :http_stream_retry, value: :bad, reason: "x"},
            {:transport_error, %Mint.TransportError{reason: :econnrefused}},
            {:transport_error, :dns_failed},
            {:transport_error, {:security_violation, :blocked}},
            send_failure(%Mint.TransportError{reason: :econnrefused}),
            send_failure(:non_public_address),
            send_failure({:security_violation, :blocked})
          ] do
        assert CallOutcome.classify(reason) == :not_sent, inspect(reason)
      end
    end

    test "a request the server rejected before running a method is :refused" do
      for reason <- [
            %{"code" => -32_700, "message" => "Parse error"},
            %{"code" => -32_600, "message" => "Invalid Request"},
            %{"code" => -32_601, "message" => "Method not found"},
            {:transport_error, {:http_error, 404, ""}},
            {:transport_error, {:unauthorized, 401, "", nil}},
            send_failure({:http_error, 429, "slow down"}),
            send_failure({:unauthorized, 401, "", nil})
          ] do
        assert CallOutcome.classify(reason) == :refused, inspect(reason)
      end
    end

    test "a timeout is always :unknown, as is anything after possible delivery" do
      for reason <- [
            :timeout,
            %{"code" => -32_602, "message" => "Invalid params"},
            %{"code" => -32_603, "message" => "Internal error"},
            %{"code" => -32_000, "message" => "Server error"},
            %ExMCP.Error.TransportError{transport: :http, reason: :outcome_unknown},
            {:transport_error, {:http_error, 502, ""}},
            {:transport_error, {:http_receive_failed, :closed}},
            send_failure({:http_receive_failed, %Mint.TransportError{reason: :closed}}),
            send_failure({:http_error, 500, "boom"}),
            send_failure(:closed),
            :something_new
          ] do
        assert CallOutcome.classify(reason) == :unknown, inspect(reason)
      end
    end
  end

  describe "returned/3" do
    test "a successful answer passes through" do
      result = %{"content" => [%{"type" => "text", "text" => "ok"}]}
      assert {:ok, ^result} = CallOutcome.returned("srv", "tool", {:ok, result})
    end

    test "an MCP error result is the tool's answer: :failed with its text" do
      result = %{"isError" => true, "content" => [%{"type" => "text", "text" => "disk full"}]}

      assert {:error, %CallFailure{outcome: :failed, tool: "tool", message: message}} =
               CallOutcome.returned("srv", "tool", {:ok, result})

      assert message =~ "disk full"
    end

    test "security regression: a tool's own answer never reads as :refused" do
      result = %{
        "isError" => true,
        "content" => [%{"type" => "text", "text" => "refused"}],
        "structuredContent" => %{"outcome" => "refused"}
      }

      assert {:error, %CallFailure{outcome: :failed}} =
               CallOutcome.returned("srv", "tool", {:ok, result})
    end

    test "an error result that declares an unknown outcome is :unknown" do
      result = %{
        "isError" => true,
        "content" => [%{"type" => "text", "text" => "write outcome unknown"}],
        "structuredContent" => %{"outcome" => "unknown"}
      }

      assert {:error, %CallFailure{outcome: :unknown}} =
               CallOutcome.returned("srv", "tool", {:ok, result})
    end

    test "an error carries a bounded message naming the server and tool" do
      assert {:error, %CallFailure{outcome: :unknown, message: message}} =
               CallOutcome.returned("srv", "tool", {:error, :timeout})

      assert message =~ "srv/tool"
      assert message =~ "timed out"

      huge = %{"code" => -32_603, "message" => String.duplicate("x", 50_000)}

      assert {:error, %CallFailure{message: message}} =
               CallOutcome.returned("srv", "tool", {:error, huge})

      assert byte_size(message) < 2_000
    end
  end

  describe "unknown_tool/2" do
    test "refuses a name that is not listed or pinned" do
      assert %CallFailure{outcome: :refused, tool: "secret", message: message} =
               CallOutcome.unknown_tool("docs", "secret")

      assert message =~ "listed" or message =~ "pinned"
      assert message =~ "docs/secret"
    end
  end

  describe "exited/3" do
    test "a client that was already gone is :not_sent; any other exit is :unknown" do
      assert %CallFailure{outcome: :not_sent} =
               CallOutcome.exited("srv", "tool", {:noproc, {GenServer, :call, []}})

      assert %CallFailure{outcome: :unknown} =
               CallOutcome.exited("srv", "tool", {:timeout, {GenServer, :call, []}})

      assert %CallFailure{outcome: :unknown} = CallOutcome.exited("srv", "tool", :shutdown)
    end
  end

  defp send_failure(reason),
    do: %{type: :transport_error, message: "Failed to send request: " <> inspect(reason)}
end
