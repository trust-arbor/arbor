defmodule Arbor.Actions.WebTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Web
  alias Browse
  alias Search
  alias Snapshot

  describe "validate_url/1" do
    test "allows https URLs" do
      assert :ok = Web.validate_url("https://example.com")
      assert :ok = Web.validate_url("https://docs.elixir-lang.org/getting-started")
    end

    test "allows http URLs" do
      assert :ok = Web.validate_url("http://example.com")
    end

    test "blocks localhost" do
      assert {:error, msg} = Web.validate_url("http://localhost/admin")
      assert msg =~ "Blocked host"
    end

    test "blocks loopback IPs" do
      assert {:error, msg} = Web.validate_url("http://127.0.0.1/admin")
      assert msg =~ "Blocked host"
    end

    test "blocks private 10.x.x.x IPs" do
      assert {:error, msg} = Web.validate_url("http://10.0.0.1/internal")
      assert msg =~ "Blocked private IP"
    end

    test "blocks private 172.16-31.x.x IPs" do
      assert {:error, msg} = Web.validate_url("http://172.16.0.1/internal")
      assert msg =~ "Blocked private IP"

      assert {:error, _} = Web.validate_url("http://172.31.255.255/internal")

      # 172.15 and 172.32 should be allowed
      assert :ok = Web.validate_url("http://172.15.0.1/external")
      assert :ok = Web.validate_url("http://172.32.0.1/external")
    end

    test "blocks private 192.168.x.x IPs" do
      assert {:error, msg} = Web.validate_url("http://192.168.1.1/router")
      assert msg =~ "Blocked private IP"
    end

    test "blocks cloud metadata endpoint" do
      assert {:error, msg} = Web.validate_url("http://169.254.169.254/latest/meta-data/")
      assert msg =~ "Blocked host"
    end

    test "blocks file:// scheme" do
      assert {:error, msg} = Web.validate_url("file:///etc/passwd")
      assert msg =~ "Blocked scheme"
    end

    test "blocks javascript: scheme" do
      assert {:error, msg} = Web.validate_url("javascript:alert(1)")
      assert msg =~ "Blocked scheme"
    end

    test "blocks ftp:// scheme" do
      assert {:error, msg} = Web.validate_url("ftp://ftp.example.com/file")
      assert msg =~ "Blocked scheme"
    end

    test "blocks data: scheme" do
      assert {:error, msg} = Web.validate_url("data:text/html,<h1>XSS</h1>")
      assert msg =~ "Blocked scheme"
    end

    test "blocks URLs without scheme" do
      assert {:error, msg} = Web.validate_url("no-scheme.example.com")
      assert msg =~ "Blocked scheme"
    end

    test "rejects non-string input" do
      assert {:error, _} = Web.validate_url(123)
      assert {:error, _} = Web.validate_url(nil)
    end
  end

  describe "Browse action schema" do
    test "has correct name and category" do
      assert Browse.name() == "web_browse"
    end

    test "declares taint roles" do
      roles = Browse.taint_roles()
      assert roles.url == :control
      assert roles.selector == :control
      assert roles.format == :data
    end

    test "generates valid tool schema" do
      tool = Browse.to_tool()
      assert tool.name == "web_browse"
      assert tool.description =~ "web page"
      assert tool.parameters_schema["required"] == ["url"]
      assert Map.has_key?(tool.parameters_schema["properties"], "url")
      assert Map.has_key?(tool.parameters_schema["properties"], "selector")
      assert Map.has_key?(tool.parameters_schema["properties"], "format")
    end

    test "rejects SSRF URLs" do
      assert {:error, msg} =
               Browse.run(
                 %{url: "http://169.254.169.254/latest/meta-data/"},
                 %{}
               )

      assert msg =~ "SSRF"
    end
  end

  describe "Search action schema" do
    test "has correct name and category" do
      assert Search.name() == "web_search"
    end

    test "declares taint roles" do
      roles = Search.taint_roles()
      assert roles.query == :control
      assert roles.max_results == :data
    end

    test "generates valid tool schema" do
      tool = Search.to_tool()
      assert tool.name == "web_search"
      assert tool.description =~ "Brave Search"
      assert tool.parameters_schema["required"] == ["query"]
      assert Map.has_key?(tool.parameters_schema["properties"], "query")
      assert Map.has_key?(tool.parameters_schema["properties"], "max_results")
    end
  end

  describe "Snapshot action schema" do
    test "has correct name and category" do
      assert Snapshot.name() == "web_snapshot"
    end

    test "declares taint roles" do
      roles = Snapshot.taint_roles()
      assert roles.url == :control
      assert roles.selector == :control
      assert roles.include_links == :data
    end

    test "generates valid tool schema" do
      tool = Snapshot.to_tool()
      assert tool.name == "web_snapshot"
      assert tool.description =~ "LLM-optimized"
      assert tool.parameters_schema["required"] == ["url"]
      assert Map.has_key?(tool.parameters_schema["properties"], "url")
      assert Map.has_key?(tool.parameters_schema["properties"], "include_links")
      assert Map.has_key?(tool.parameters_schema["properties"], "max_content_length")
    end

    test "rejects SSRF URLs" do
      assert {:error, msg} =
               Snapshot.run(
                 %{url: "http://127.0.0.1:8080/admin"},
                 %{}
               )

      assert msg =~ "SSRF"
    end
  end
end
