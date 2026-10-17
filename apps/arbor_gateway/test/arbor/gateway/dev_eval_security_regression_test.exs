defmodule Arbor.Gateway.DevEvalSecurityRegressionTest do
  @moduledoc """
  Security regression: `POST /api/dev/eval` used to `Code.eval_string` the HTTP
  JSON `code` field. That is untrusted network input (even on localhost, even
  when `dev_endpoints` is opted in). Module-body and expression side effects
  ran in the Gateway process.

  The payload plants `send(self(), :pwned_http_eval)` so a received message is
  direct proof that the request body reached `Code.eval_string`. This file
  fails on the pre-fix router (status 200, message delivered) and passes after
  HTTP eval is refused and the loader call is gone from the module AST.
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Dev.Router

  @opts Router.init([])
  @router_source Path.expand("../../../lib/arbor/gateway/dev/router.ex", __DIR__)

  @payload """
  send(self(), :pwned_http_eval)
  1 + 2
  """

  setup do
    previous = Application.get_env(:arbor_gateway, :dev_endpoints)
    Application.put_env(:arbor_gateway, :dev_endpoints, true)
    on_exit(fn -> Application.put_env(:arbor_gateway, :dev_endpoints, previous) end)
    :ok
  end

  test "security regression: HTTP request bodies cannot reach Code.eval_string" do
    conn =
      conn(:post, "/eval", Jason.encode!(%{code: @payload}))
      |> put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Router.call(@opts)

    refute_received :pwned_http_eval

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "forbidden"
    assert is_binary(body["reason"])
    assert body["reason"] =~ "eval"
    refute Map.has_key?(body, "result")
  end

  test "security regression: Dev.Router no longer calls Code.eval_string" do
    source = File.read!(@router_source)
    {:ok, ast} = Code.string_to_quoted(source, file: @router_source)

    hits =
      ast
      |> code_loader_calls()
      |> Enum.map(&elem(&1, 0))

    refute "Code.eval_string" in hits
    refute "apply(Code, :eval_string)" in hits
    refute ":rpc.call(Code, :eval_string)" in hits
  end

  defp code_loader_calls(ast) do
    loaders = MapSet.new([:eval_string, :eval_quoted, :eval_file, :compile_string])

    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, acc ->
        case site(node, loaders) do
          nil -> {node, acc}
          hit -> {node, [hit | acc]}
        end
      end)

    Enum.reverse(hits)
  end

  defp site({{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, _args}, loaders)
       when is_atom(fun) do
    if MapSet.member?(loaders, fun), do: {"Code.#{fun}", meta[:line]}
  end

  defp site({:apply, meta, [{:__aliases__, _, [:Code]}, fun, _args]}, loaders)
       when is_atom(fun) do
    if MapSet.member?(loaders, fun), do: {"apply(Code, :#{fun})", meta[:line]}
  end

  defp site({{:., _, [:rpc, :call]}, meta, [_node, {:__aliases__, _, [:Code]}, fun | _]}, loaders)
       when is_atom(fun) do
    if MapSet.member?(loaders, fun), do: {":rpc.call(Code, :#{fun})", meta[:line]}
  end

  defp site(_node, _loaders), do: nil
end
