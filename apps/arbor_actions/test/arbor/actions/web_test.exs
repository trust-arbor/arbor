defmodule Arbor.Actions.WebTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Actions.Web
  alias Arbor.Actions.Web.Browse
  alias Arbor.Actions.Web.ExaSearch
  alias Arbor.Actions.Web.Search
  alias Arbor.Actions.Web.Snapshot
  alias Arbor.Actions.Web.TinyfishSearch

  defmodule PublicResolver do
    def resolve_all(_host), do: {:ok, [{8, 8, 8, 8}]}
  end

  describe "validate_url/1" do
    @tag :security_regression
    test "security regression: accepts DNS HTTPS only through the pin-capable Req path" do
      assert :ok =
               Web.validate_url("https://example.com", %{ssrf_resolver: PublicResolver})
    end

    test "allows public IP literal URLs" do
      assert :ok = Web.validate_url("https://8.8.8.8")
      assert :ok = Web.validate_url("http://172.15.0.1")
    end

    test "blocks localhost" do
      assert {:error, msg} = Web.validate_url("http://localhost/admin")
      assert msg =~ "SSRF prevention"
    end

    test "blocks loopback IPs" do
      assert {:error, msg} = Web.validate_url("http://127.0.0.1/admin")
      assert msg =~ "SSRF prevention"
    end

    test "blocks private 10.x.x.x IPs" do
      assert {:error, msg} = Web.validate_url("http://10.0.0.1/internal")
      assert msg =~ "private_ip"
    end

    test "blocks private 172.16-31.x.x IPs" do
      assert {:error, msg} = Web.validate_url("http://172.16.0.1/internal")
      assert msg =~ "private_ip"

      assert {:error, _} = Web.validate_url("http://172.31.255.255/internal")

      # 172.15 and 172.32 should be allowed
      assert :ok = Web.validate_url("http://172.15.0.1/external")
      assert :ok = Web.validate_url("http://172.32.0.1/external")
    end

    test "blocks private 192.168.x.x IPs" do
      assert {:error, msg} = Web.validate_url("http://192.168.1.1/router")
      assert msg =~ "private_ip"
    end

    test "blocks cloud metadata endpoint" do
      assert {:error, msg} = Web.validate_url("http://169.254.169.254/latest/meta-data/")
      assert msg =~ "metadata_endpoint"
    end

    test "blocks file:// scheme" do
      assert {:error, msg} = Web.validate_url("file:///etc/passwd")
      assert msg =~ "blocked_scheme"
    end

    test "blocks javascript: scheme" do
      assert {:error, msg} = Web.validate_url("javascript:alert(1)")
      assert msg =~ "blocked_scheme"
    end

    test "blocks ftp:// scheme" do
      assert {:error, msg} = Web.validate_url("ftp://ftp.example.com/file")
      assert msg =~ "blocked_scheme"
    end

    test "blocks data: scheme" do
      assert {:error, msg} = Web.validate_url("data:text/html,<h1>XSS</h1>")
      assert msg =~ "blocked_scheme"
    end

    test "blocks URLs without scheme" do
      assert {:error, msg} = Web.validate_url("no-scheme.example.com")
      assert msg =~ "invalid_url"
    end

    test "rejects non-string input" do
      assert {:error, _} = Web.validate_url(123)
      assert {:error, _} = Web.validate_url(nil)
    end
  end

  describe "fetch_page/3" do
    @tag :security_regression
    test "security regression: an action fetch pins DNS while preserving HTTPS authority" do
      parent = self()

      transport = fn request, _finch_name, _finch_options ->
        send(parent, {:web_request, request})

        {:ok,
         %Finch.Response{
           status: 200,
           body: "<h1>safe</h1>",
           headers: [],
           trailers: []
         }}
      end

      assert {:ok, page} =
               Web.fetch_page("https://public.example/page", [], %{
                 ssrf_resolver: PublicResolver,
                 ssrf_finch_request: transport
               })

      assert page.body == "<h1>safe</h1>"

      assert_receive {:web_request, %Finch.Request{host: {8, 8, 8, 8}, headers: headers}}

      assert {"host", "public.example"} in headers
    end

    @tag spec: "KSEC-013"
    @tag security: :regression
    test "security regression: an oversized pinned response fails closed at the action boundary" do
      oversized = String.duplicate("x", 1_048_577)

      transport = fn _request, _finch_name, _finch_options ->
        {:ok,
         %Finch.Response{
           status: 200,
           body: oversized,
           headers: [],
           trailers: []
         }}
      end

      assert {:error, {:response_bytes_exceeded, 1_048_576}} =
               Web.fetch_page("https://public.example/oversized", [], %{
                 ssrf_resolver: PublicResolver,
                 ssrf_finch_request: transport
               })
    end

    @tag :security_regression
    test "security regression: redirects cannot cross origin to loopback" do
      parent = self()

      transport = fn request, _finch_name, _finch_options ->
        send(parent, {:web_request, request})

        {:ok,
         %Finch.Response{
           status: 302,
           body: "",
           headers: [{"location", "http://127.0.0.1/admin"}],
           trailers: []
         }}
      end

      assert {:error, {:cross_origin_redirect, "http://127.0.0.1/admin"}} =
               Web.fetch_page("https://public.example/start", [], %{
                 ssrf_resolver: PublicResolver,
                 ssrf_finch_request: transport
               })

      assert_receive {:web_request, %Finch.Request{host: {8, 8, 8, 8}}}
      refute_receive {:web_request, _second_request}
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: redirects share one monotonic whole-operation deadline" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _request, _finch_name, _finch_options ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
        Process.sleep(160)

        if attempt == 0 do
          {:ok,
           %Finch.Response{
             status: 302,
             body: "",
             headers: [{"location", "/second"}],
             trailers: []
           }}
        else
          {:ok, %Finch.Response{status: 200, body: "late", headers: [], trailers: []}}
        end
      end

      started_at = System.monotonic_time(:millisecond)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Web.fetch_page("https://public.example/start", [receive_timeout: 250], %{
                 ssrf_resolver: PublicResolver,
                 ssrf_finch_request: transport
               })

      assert Agent.get(attempts, & &1) == 2
      assert System.monotonic_time(:millisecond) - started_at < 500
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: a fetch refuses cross-origin redirects" do
      parent = self()

      transport = fn request, _finch_name, _finch_options ->
        send(parent, {:web_request, request})

        {:ok,
         %Finch.Response{
           status: 302,
           body: "",
           headers: [{"location", "https://other.example/escaped"}],
           trailers: []
         }}
      end

      assert {:error, {:cross_origin_redirect, "https://other.example/escaped"}} =
               Web.fetch_page("https://public.example/start", [], %{
                 ssrf_resolver: PublicResolver,
                 ssrf_finch_request: transport
               })

      assert_receive {:web_request, _request}
      refute_receive {:web_request, _second_request}
    end

    @tag :security_regression
    @tag spec: "KSEC-013"
    test "security regression: invalid UTF-8 is rejected before string consumers" do
      transport = fn _request, _finch_name, _finch_options ->
        {:ok, %Finch.Response{status: 200, body: <<0xFF>>, headers: [], trailers: []}}
      end

      assert {:error, {:invalid_response, :invalid_utf8}} =
               Web.fetch_page("https://public.example/invalid", [], %{
                 ssrf_resolver: PublicResolver,
                 ssrf_finch_request: transport
               })
    end
  end

  describe "Browse action schema" do
    test "has correct name and category" do
      assert Browse.name() == "web_browse"
    end

    test "declares taint roles" do
      roles = Browse.taint_roles()
      assert roles.url == {:control, requires: [:ssrf]}
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

    @tag :security_regression
    test "direct run/2 without the envelope is unauthorized" do
      assert {:error, "Unauthorized: :action_principal_authority_required"} =
               Browse.run(
                 %{url: "http://169.254.169.254/latest/meta-data/"},
                 %{}
               )
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

    @tag :security_regression
    test "direct run/2 without the envelope is unauthorized" do
      assert {:error, "Unauthorized: :action_principal_authority_required"} =
               Search.run(%{query: "p1d-e"}, %{})
    end
  end

  describe "Snapshot action schema" do
    test "has correct name and category" do
      assert Snapshot.name() == "web_snapshot"
    end

    test "declares taint roles" do
      roles = Snapshot.taint_roles()
      assert roles.url == {:control, requires: [:ssrf]}
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

    @tag :security_regression
    test "direct run/2 without the envelope is unauthorized" do
      assert {:error, "Unauthorized: :action_principal_authority_required"} =
               Snapshot.run(
                 %{url: "http://127.0.0.1:8080/admin"},
                 %{}
               )
    end
  end

  describe "ExaSearch action" do
    @tag :security_regression
    test "direct run/2 without the envelope is unauthorized" do
      assert {:error, "Unauthorized: :action_principal_authority_required"} =
               ExaSearch.run(%{query: "p1d-e"}, %{})
    end
  end

  describe "TinyfishSearch action" do
    @tag :security_regression
    test "direct run/2 without the envelope is unauthorized" do
      assert {:error, "Unauthorized: :action_principal_authority_required"} =
               TinyfishSearch.run(%{query: "p1d-e"}, %{})
    end
  end
end
