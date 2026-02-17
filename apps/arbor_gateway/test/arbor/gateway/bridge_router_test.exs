defmodule Arbor.Gateway.Bridge.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Bridge.Router

  @moduletag :fast

  @opts Router.init([])

  # The Bridge Router does not have its own Plug.Parsers (the main router
  # handles parsing). We need to parse the JSON body before calling the router.
  @parsers_opts Plug.Parsers.init(parsers: [:json], json_decoder: Jason)

  defp parsed_post(path, body) do
    conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(@parsers_opts)
  end

  # ===========================================================================
  # authorize_tool endpoint — denial paths (fail-closed security)
  # ===========================================================================

  describe "POST /authorize_tool — tool authorization denial" do
    test "denies tool when authorization services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-001",
          tool_name: "Read",
          tool_input: %{file_path: "/tmp/test.txt"},
          cwd: "/tmp"
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      # Bridge router catches errors and returns deny (fail-closed security)
      assert response["decision"] == "deny"
      assert is_binary(response["reason"])
    end

    test "denies Bash tool with dangerous command (rm)" do
      body =
        Jason.encode!(%{
          session_id: "test-session-002",
          tool_name: "Bash",
          tool_input: %{command: "rm -rf /"},
          cwd: "/tmp"
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies Bash tool with sudo" do
      body =
        Jason.encode!(%{
          session_id: "test-session-003",
          tool_name: "Bash",
          tool_input: %{command: "sudo apt-get install malware"},
          cwd: "/home/user"
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies Bash tool with kill" do
      body =
        Jason.encode!(%{
          session_id: "test-session-kill",
          tool_name: "Bash",
          tool_input: %{command: "kill -9 1"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies Write tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-004",
          tool_name: "Write",
          tool_input: %{file_path: "/etc/passwd"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies Edit tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-005",
          tool_name: "Edit",
          tool_input: %{file_path: "/tmp/edit.txt"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies Grep tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-grep",
          tool_name: "Grep",
          tool_input: %{pattern: "password", path: "/etc"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies Glob tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-glob",
          tool_name: "Glob",
          tool_input: %{pattern: "**/*.env"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies Task (agent spawn) tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-task",
          tool_name: "Task",
          tool_input: %{description: "do something"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies WebFetch tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-006",
          tool_name: "WebFetch",
          tool_input: %{url: "https://evil.example.com"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies WebSearch tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-search",
          tool_name: "WebSearch",
          tool_input: %{query: "secrets"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end

    test "denies unknown/generic tool when services are unavailable" do
      body =
        Jason.encode!(%{
          session_id: "test-session-007",
          tool_name: "CustomDangerTool",
          tool_input: %{param: "value"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] == "deny"
    end
  end

  # ===========================================================================
  # authorize_tool endpoint — request validation
  # ===========================================================================

  describe "POST /authorize_tool — request validation" do
    test "returns 400 for missing required fields" do
      body = Jason.encode!(%{})
      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "invalid_params"
    end

    test "returns 400 for missing session_id" do
      body = Jason.encode!(%{tool_name: "Read"})
      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 400
    end

    test "returns 400 for missing tool_name" do
      body = Jason.encode!(%{session_id: "test-session"})
      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 400
    end

    test "returns 400 for empty session_id" do
      body = Jason.encode!(%{session_id: "", tool_name: "Read"})
      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 400
    end

    test "accepts minimal valid request (session_id + tool_name)" do
      body =
        Jason.encode!(%{
          session_id: "test-session-min",
          tool_name: "Read"
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      # Should get through validation (200) even if auth fails (deny)
      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["decision"] in ["allow", "deny"]
    end
  end

  # ===========================================================================
  # 404 for unknown routes
  # ===========================================================================

  describe "unknown routes" do
    test "returns 404 for GET requests to authorize_tool" do
      conn =
        conn(:get, "/authorize_tool")
        |> Router.call(@opts)

      assert conn.status == 404
    end

    test "returns 404 for unknown paths" do
      conn =
        conn(:get, "/nonexistent")
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end

  # ===========================================================================
  # Response format verification
  # ===========================================================================

  describe "response format" do
    test "denial responses are valid JSON with decision and reason fields" do
      body =
        Jason.encode!(%{
          session_id: "format-test",
          tool_name: "Read",
          tool_input: %{file_path: "/tmp/test"},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      # Response must have decision field
      assert Map.has_key?(response, "decision")
      assert response["decision"] in ["allow", "deny"]

      # Denial responses must include a reason
      if response["decision"] == "deny" do
        assert Map.has_key?(response, "reason")
        assert is_binary(response["reason"])
        assert byte_size(response["reason"]) > 0
      end
    end

    test "response has JSON content type" do
      body =
        Jason.encode!(%{
          session_id: "ct-test",
          tool_name: "Read",
          tool_input: %{},
          cwd: "."
        })

      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert {"content-type", content_type} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert content_type =~ "application/json"
    end

    test "validation error responses include field-level details" do
      body = Jason.encode!(%{})
      conn = parsed_post("/authorize_tool", body) |> Router.call(@opts)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "invalid_params"
      assert is_list(response["details"])
    end
  end
end
