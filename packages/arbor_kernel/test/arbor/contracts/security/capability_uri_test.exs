defmodule Arbor.Contracts.Security.CapabilityUriTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.CapabilityUri

  @moduletag :fast

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

    test "security regression: parameterized and percent-encoded dot segments are rejected" do
      # The existing closed-set error for a traversal segment is
      # `{:error, :traversal_segment}` (see CapabilityProfile / CapsFile).
      # Exact ".." is already treated as traversal after a successful parse;
      # these variants must fail at parse with that same shape so a later
      # `;param` strip or percent-decode cannot turn them into parent refs.
      disguised_dot_segments = [
        "..;",
        "..;x",
        "%2e%2e",
        "%2E%2E;",
        ".%2e",
        "%2e.",
        ".;",
        "%2e"
      ]

      Enum.each(disguised_dot_segments, fn segment ->
        uri = "arbor://fs/read/" <> segment

        assert {:error, :traversal_segment} = CapabilityUri.parse(uri),
               "expected #{inspect(uri)} to be rejected as :traversal_segment"
      end)

      # Existing valid URIs from this suite, including names that contain
      # dots or semicolons but do not normalize to "." or "..".
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/project/src")
      assert {:ok, _} = CapabilityUri.parse("arbor://action/git/commit")
      assert {:ok, _} = CapabilityUri.parse("arbor://**")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/**")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/*")
      assert {:ok, _} = CapabilityUri.parse("arbor://mcp/")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/docs/secret.txt")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/docs/file.txt")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/write/project/file.txt")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/my..file")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/..hidden")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/version.1.0")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/.hidden")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/file;draft")
      assert {:ok, _} = CapabilityUri.parse("arbor://fs/read/foo.bar;meta=1")
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

  describe "capability_match?/2" do
    test "concrete capabilities only match the exact canonical resource" do
      assert CapabilityUri.capability_match?("arbor://fs/read/docs", "arbor://fs/read/docs/")

      refute CapabilityUri.capability_match?(
               "arbor://fs/read/docs",
               "arbor://fs/read/docs/secret.txt"
             )
    end

    test "terminal wildcard capabilities match descendants on segment boundaries" do
      assert CapabilityUri.capability_match?(
               "arbor://fs/read/docs/**",
               "arbor://fs/read/docs/secret.txt"
             )

      refute CapabilityUri.capability_match?(
               "arbor://fs/read/docs/**",
               "arbor://fs/read/docs_evil/secret.txt"
             )
    end

    @tag spec: "SSEC-015"
    test "security regression: a single wildcard matches exactly one descendant segment" do
      assert CapabilityUri.capability_match?(
               "arbor://fs/read/docs/*",
               "arbor://fs/read/docs/file.txt"
             )

      refute CapabilityUri.capability_match?(
               "arbor://fs/read/docs/*",
               "arbor://fs/read/docs/deep/secret.txt"
             )

      refute CapabilityUri.capability_match?(
               "arbor://fs/read/docs/*",
               "arbor://fs/read/docs"
             )
    end

    test "root wildcard capability matches any valid arbor URI" do
      assert CapabilityUri.capability_match?("arbor://**", "arbor://action/git/status")
      assert CapabilityUri.capability_match?("arbor://**", "arbor://fs/read/docs")
    end

    test "security regression: traversal-like URI segments fail closed" do
      refute CapabilityUri.capability_match?(
               "arbor://fs/read/docs/**",
               "arbor://fs/read/docs/../secrets"
             )

      refute CapabilityUri.capability_match?(
               "arbor://fs/read/docs/../secrets/**",
               "arbor://fs/read/secrets/key"
             )
    end
  end

  describe "capability_subset?/2" do
    test "wildcard parent covers concrete and narrower wildcard children" do
      assert CapabilityUri.capability_subset?(
               "arbor://fs/write/project/file.txt",
               "arbor://fs/write/project/**"
             )

      assert CapabilityUri.capability_subset?(
               "arbor://fs/write/project/src/**",
               "arbor://fs/write/project/**"
             )
    end

    test "concrete parent is exact and does not cover a child path" do
      refute CapabilityUri.capability_subset?(
               "arbor://fs/write/project/file.txt",
               "arbor://fs/write/project"
             )
    end

    test "rejects wider children and invalid URI patterns" do
      refute CapabilityUri.capability_subset?(
               "arbor://fs/write/**",
               "arbor://fs/write/project/**"
             )

      refute CapabilityUri.capability_subset?("not-a-uri", "arbor://fs/write/**")
    end

    @tag spec: "SSEC-015"
    test "security regression: single-wildcard delegation cannot widen to deeper descendants" do
      assert CapabilityUri.capability_subset?(
               "arbor://fs/write/project/file.txt",
               "arbor://fs/write/project/*"
             )

      assert CapabilityUri.capability_subset?(
               "arbor://fs/write/project/*",
               "arbor://fs/write/project/*"
             )

      refute CapabilityUri.capability_subset?(
               "arbor://fs/write/project/src/file.txt",
               "arbor://fs/write/project/*"
             )

      refute CapabilityUri.capability_subset?(
               "arbor://fs/write/project/src/*",
               "arbor://fs/write/project/*"
             )

      refute CapabilityUri.capability_subset?(
               "arbor://fs/write/project/**",
               "arbor://fs/write/project/*"
             )
    end
  end
end
