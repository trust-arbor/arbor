defmodule Arbor.Contracts.Security.CapabilityUriTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.CapabilityUri

  describe "parse/1" do
    test "parses a concrete resource URI" do
      assert {:ok,
              %CapabilityUri{
                scheme: "arbor",
                domain: "fs",
                operation: "read",
                path: "project/src",
                segments: ["fs", "read", "project", "src"],
                wildcard: :none
              }} = CapabilityUri.parse("arbor://fs/read/project/src")
    end

    test "parses canonical singular action URIs" do
      assert {:ok,
              %CapabilityUri{
                domain: "action",
                operation: "git",
                path: "commit",
                wildcard: :none
              }} = CapabilityUri.parse("arbor://action/git/commit")
    end

    test "parses root and terminal wildcards" do
      assert {:ok, %CapabilityUri{domain: nil, operation: nil, wildcard: :recursive}} =
               CapabilityUri.parse("arbor://**")

      assert {:ok, %CapabilityUri{domain: "fs", operation: "read", wildcard: :recursive}} =
               CapabilityUri.parse("arbor://fs/read/**")

      assert {:ok, %CapabilityUri{domain: "fs", operation: "read", wildcard: :single}} =
               CapabilityUri.parse("arbor://fs/read/*")
    end

    test "accepts trailing slash prefixes while canonicalizing without the slash" do
      assert {:ok, parsed} = CapabilityUri.parse("arbor://mcp/")
      assert parsed.segments == ["mcp"]
      assert CapabilityUri.canonical(parsed) == "arbor://mcp"
    end

    test "rejects non-arbor schemes" do
      assert {:error, :invalid_scheme} = CapabilityUri.parse("https://example.com")
    end

    test "rejects empty and internally empty segments" do
      assert {:error, :missing_domain} = CapabilityUri.parse("arbor://")
      assert {:error, :empty_segment} = CapabilityUri.parse("arbor://fs//read")
    end

    test "rejects non-terminal wildcards" do
      assert {:error, :non_terminal_wildcard} =
               CapabilityUri.parse("arbor://fs/**/read")
    end

    test "rejects invalid domain and operation segments" do
      assert {:error, {:invalid_domain, "FS"}} = CapabilityUri.parse("arbor://FS/read")

      assert {:error, {:invalid_operation, "read-files"}} =
               CapabilityUri.parse("arbor://fs/read-files")
    end
  end

  describe "parse!/1" do
    test "returns the parsed URI on success" do
      assert %CapabilityUri{domain: "fs"} = CapabilityUri.parse!("arbor://fs/read")
    end

    test "raises on invalid URI" do
      assert_raise ArgumentError, ~r/invalid Arbor capability URI/, fn ->
        CapabilityUri.parse!("not-a-uri")
      end
    end
  end

  describe "prefix_match?/2" do
    test "matches exact and descendant URIs on segment boundaries" do
      assert CapabilityUri.prefix_match?("arbor://fs/read", "arbor://fs/read")
      assert CapabilityUri.prefix_match?("arbor://fs/read", "arbor://fs/read/project")
    end

    test "does not match partial segment prefixes" do
      refute CapabilityUri.prefix_match?("arbor://fs/read", "arbor://fs/reader/project")
      refute CapabilityUri.prefix_match?("arbor://action", "arbor://actions/execute/file.read")
    end

    test "matches trailing-slash registry prefixes by segment" do
      assert CapabilityUri.prefix_match?("arbor://mcp/", "arbor://mcp/server")
      refute CapabilityUri.prefix_match?("arbor://mcp/", "arbor://mcproxy/server")
    end

    test "matches wildcard prefixes" do
      assert CapabilityUri.prefix_match?("arbor://fs/read/**", "arbor://fs/read/project/src")
      assert CapabilityUri.prefix_match?("arbor://**", "arbor://anything/goes")
    end

    test "returns false for invalid input" do
      refute CapabilityUri.prefix_match?("not-a-uri", "arbor://fs/read")
      refute CapabilityUri.prefix_match?("arbor://fs/read", "not-a-uri")
    end
  end
end
