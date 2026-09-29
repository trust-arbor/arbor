defmodule Arbor.Gateway.MCP.ClientConfigCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.MCP.ClientConfigCore

  @moduletag :fast

  test "string-keyed configs from profile metadata read the same as atom-keyed ones" do
    string_keyed = %{
      "transport" => "stdio",
      "command" => ["npx", "server"],
      "env" => %{"K" => "v"}
    }

    atom_keyed = %{transport: :stdio, command: ["npx", "server"], env: %{"K" => "v"}}

    assert ClientConfigCore.normalize("s", string_keyed) ==
             ClientConfigCore.normalize("s", atom_keyed)

    assert {:ok, %{transport: :stdio, command: ["npx", "server"], server_name: "s"}} =
             ClientConfigCore.normalize("s", string_keyed)
  end

  test "a string transport is honored, not replaced by the :stdio default" do
    assert {:ok, %{transport: :http, url: "https://mcp.example"}} =
             ClientConfigCore.normalize("s", %{
               "transport" => "http",
               "url" => "https://mcp.example"
             })

    assert {:ok, %{transport: :sse}} =
             ClientConfigCore.normalize("s", %{
               "transport" => "sse",
               "url" => "http://127.0.0.1:1"
             })
  end

  test "a bare command string becomes a one-element command list" do
    assert {:ok, %{command: ["server-bin"]}} =
             ClientConfigCore.normalize("s", %{"command" => "server-bin"})
  end

  test "each transport's required field is validated instead of failing later" do
    for {config, field} <- [
          {%{"transport" => "stdio"}, :command},
          {%{"transport" => "stdio", "command" => []}, :command},
          {%{"transport" => "stdio", "command" => ["ok", 1]}, :command},
          {%{"transport" => "http"}, :url},
          {%{"transport" => "http", "url" => "ftp://x"}, :url},
          {%{"transport" => "beam"}, :server},
          {%{"transport" => "carrier_pigeon", "command" => ["x"]}, :transport},
          {%{transport: :bogus, command: ["x"]}, :transport},
          {%{"command" => ["x"], "env" => ["K=v"]}, :env}
        ] do
      assert ClientConfigCore.normalize("s", config) == {:error, {:invalid_mcp_config, field}},
             "expected #{inspect(config)} to fail on #{field}"
    end
  end

  test "unknown string keys are dropped rather than atomized; unknown atom keys survive" do
    {:ok, config} =
      ClientConfigCore.normalize("s", %{
        "command" => ["x"],
        "definitely_not_an_existing_atom_d7" => 1,
        custom_opt: true
      })

    refute Map.has_key?(config, "definitely_not_an_existing_atom_d7")
    assert config.custom_opt == true
  end
end
