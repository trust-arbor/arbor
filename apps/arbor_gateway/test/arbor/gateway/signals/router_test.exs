defmodule Arbor.Gateway.Signals.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  @moduletag :fast

  alias Arbor.Gateway.Signals.Router

  @opts Router.init([])

  describe "POST /:source/:type" do
    test "accepts valid claude signal type" do
      conn =
        conn(:post, "/claude/session_start", Jason.encode!(%{session_id: "s1"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 202
      assert Jason.decode!(conn.resp_body)["status"] == "accepted"
    end

    test "accepts valid sdlc signal type" do
      conn =
        conn(:post, "/sdlc/session_started", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 202
    end

    test "rejects unknown source" do
      conn =
        conn(:post, "/unknown/session_start", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "rejected"
      assert body["reason"] =~ "unknown source"
    end

    test "rejects unknown type for claude source" do
      conn =
        conn(:post, "/claude/invalid_type", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["reason"] =~ "unknown type"
    end

    test "rejects unknown type for sdlc source" do
      conn =
        conn(:post, "/sdlc/invalid_type", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
    end

    test "all claude signal types are accepted" do
      types = ~w(session_start session_end subagent_stop notification
                  tool_used idle permission_request pre_compact
                  pre_tool_use user_prompt)

      for type <- types do
        conn =
          conn(:post, "/claude/#{type}", Jason.encode!(%{}))
          |> put_req_header("content-type", "application/json")
          |> Router.call(@opts)

        assert conn.status == 202, "Expected 202 for claude/#{type}, got #{conn.status}"
      end
    end

    test "all sdlc signal types are accepted" do
      types = ~w(session_started session_complete)

      for type <- types do
        conn =
          conn(:post, "/sdlc/#{type}", Jason.encode!(%{}))
          |> put_req_header("content-type", "application/json")
          |> Router.call(@opts)

        assert conn.status == 202, "Expected 202 for sdlc/#{type}, got #{conn.status}"
      end
    end
  end

  describe "match fallback" do
    test "returns 404 for unmatched routes" do
      conn =
        conn(:get, "/nonexistent")
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end
end
