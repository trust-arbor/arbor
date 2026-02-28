defmodule Arbor.Security.OIDC.DeviceFlowTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.OIDC.DeviceFlow

  @moduletag :fast

  describe "start/1" do
    test "returns error when issuer is unreachable" do
      config = %{
        issuer: "https://nonexistent.arbor-test-oidc.invalid",
        client_id: "test-client"
      }

      assert {:error, {:http_request_failed, _}} = DeviceFlow.start(config)
    end
  end

  describe "refresh/2" do
    test "returns error when issuer is unreachable" do
      config = %{
        issuer: "https://nonexistent.arbor-test-oidc.invalid",
        client_id: "test-client"
      }

      assert {:error, {:http_request_failed, _}} = DeviceFlow.refresh(config, "fake-refresh-token")
    end
  end
end
