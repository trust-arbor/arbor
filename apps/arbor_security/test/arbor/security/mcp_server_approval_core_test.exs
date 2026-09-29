defmodule Arbor.Security.McpServerApprovalCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Security.McpServerApprovalCore, as: Core

  @moduletag :fast

  defp uri!(name, config) do
    {:ok, uri} = Core.resource_uri(name, config)
    uri
  end

  test "equivalent configs share one approval regardless of key form or defaults" do
    base = uri!("gh", %{transport: :stdio, command: ["gh-server"], env: %{"T" => "1"}})

    assert uri!("gh", %{
             "transport" => "stdio",
             "command" => ["gh-server"],
             "env" => %{"T" => "1"}
           }) ==
             base

    assert uri!("gh", %{command: "gh-server", env: %{T: "1"}}) == base

    # Manager-added bookkeeping keys do not change what the approval covers.
    assert uri!("gh", %{
             transport: :stdio,
             command: ["gh-server"],
             env: %{"T" => "1"},
             agent_id: "agent_x",
             server_name: "gh",
             auto_discover: true
           }) == base
  end

  test "changing what runs or where it connects changes the approval" do
    base = %{transport: :stdio, command: ["gh-server"], env: %{"T" => "1"}}
    uri = uri!("gh", base)

    for changed <- [
          %{base | command: ["gh-server", "--evil"]},
          %{base | env: %{"T" => "2"}},
          %{transport: :http, url: "https://mcp.example"},
          Map.put(base, :url, "https://elsewhere")
        ] do
      refute uri!("gh", changed) == uri, "expected #{inspect(changed)} to need a new approval"
    end

    refute uri!("other-name", base) == uri
  end

  test "the server name is hashed, so it can never become URI syntax" do
    for name <- ["**", "a/b", "../x", "x y"] do
      uri = uri!(name, %{command: ["x"]})
      assert CapabilityUri.prefix_match?(Core.prefix(), uri)

      assert [_hash, _digest] =
               uri |> String.replace_prefix(Core.prefix() <> "/", "") |> String.split("/")

      refute String.contains?(uri, name)
    end
  end

  test "a missing or blank name is invalid" do
    assert {:error, :invalid_mcp_server} = Core.resource_uri("", %{command: ["x"]})
    assert {:error, :invalid_mcp_server} = Core.resource_uri(nil, %{command: ["x"]})
  end
end
