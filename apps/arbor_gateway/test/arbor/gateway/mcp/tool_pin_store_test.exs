defmodule Arbor.Gateway.MCP.ToolPinStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.MCP.ToolFingerprintCore
  alias Arbor.Gateway.MCP.ToolPinStore
  alias Arbor.Gateway.MCP.ToolPinStoreCore

  @moduletag :fast

  @search %{
    "name" => "search",
    "description" => "Search the project docs",
    "inputSchema" => %{"type" => "object"}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-pin-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "identity follows the MCP server approval URI" do
    config = %{transport: :stdio, command: ["npx", "docs"]}
    {:ok, uri} = Arbor.Security.mcp_server_approval_uri("docs", config)
    assert ToolPinStore.identity("docs", config) == uri
  end

  test "missing store is a first run with empty pins", %{dir: dir} do
    identity = ToolPinStore.identity("docs", %{transport: :stdio, command: ["npx", "docs"]})
    File.rm_rf!(dir)
    assert {:ok, %{}} = ToolPinStore.load(identity, dir: dir)
  end

  test "save then load returns the accepted pins", %{dir: dir} do
    identity = ToolPinStore.identity("docs", %{transport: :stdio, command: ["npx", "docs"]})
    pins = %{"search" => ToolFingerprintCore.fingerprint(@search)}

    assert :ok = ToolPinStore.save(identity, pins, dir: dir)
    assert {:ok, ^pins} = ToolPinStore.load(identity, dir: dir)
  end

  test "drop removes pins for that identity only", %{dir: dir} do
    docs = ToolPinStore.identity("docs", %{transport: :stdio, command: ["npx", "docs"]})
    other = ToolPinStore.identity("other", %{transport: :stdio, command: ["npx", "other"]})
    pins = %{"search" => ToolFingerprintCore.fingerprint(@search)}

    assert :ok = ToolPinStore.save(docs, pins, dir: dir)
    assert :ok = ToolPinStore.save(other, pins, dir: dir)
    assert :ok = ToolPinStore.drop(docs, dir: dir)
    assert {:ok, %{}} = ToolPinStore.load(docs, dir: dir)
    assert {:ok, ^pins} = ToolPinStore.load(other, dir: dir)
  end

  test "corrupt JSON is unreadable, not an empty first run", %{dir: dir} do
    identity = ToolPinStore.identity("docs", %{transport: :stdio, command: ["npx", "docs"]})
    pins = %{"search" => ToolFingerprintCore.fingerprint(@search)}
    assert :ok = ToolPinStore.save(identity, pins, dir: dir)

    path = Path.join(dir, ToolPinStoreCore.file_name(identity))
    assert :ok = File.write(path, "{not-json")
    assert {:error, :unreadable} = ToolPinStore.load(identity, dir: dir)
  end

  test "an identity mismatch in the file is unreadable", %{dir: dir} do
    identity = ToolPinStore.identity("docs", %{transport: :stdio, command: ["npx", "docs"]})
    {:ok, body} = ToolPinStoreCore.encode("arbor://mcp_server/connect/other/ffff", %{})
    path = Path.join(dir, ToolPinStoreCore.file_name(identity))
    File.write!(path, body)
    assert {:error, :unreadable} = ToolPinStore.load(identity, dir: dir)
  end
end
