defmodule Arbor.Agent.Eval.SecurityReview.AnthropicLoopTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.SecurityReview.{AnthropicLoop, Tools}

  defp scope do
    dir = Path.join(System.tmp_dir!(), "anthloop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\n  def authorize, do: :ok\nend\n")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "executes a tool_use round, feeds the result back, returns the final text" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    # Round 1: model asks to read a.ex. Round 2: model emits the final findings text.
    post = fn _url, _headers, body, _recv ->
      n = Agent.get_and_update(calls, &{&1, &1 + 1})

      case n do
        0 ->
          # the request must carry our tools in Anthropic shape
          assert Enum.any?(body["tools"], &(&1["name"] == "read_file"))

          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "t1",
                 "name" => "read_file",
                 "input" => %{"path" => "a.ex"}
               }
             ]
           }}

        _ ->
          # the prior turn's tool_result (the file content) must have been fed back
          last_user = body["messages"] |> Enum.reverse() |> Enum.find(&(&1["role"] == "user"))
          [tr | _] = last_user["content"]
          assert tr["type"] == "tool_result"
          assert tr["content"] =~ "def authorize"

          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "[{\"category\":\"fail_open_authz\"}]"}]
           }}
      end
    end

    assert {:ok, text} =
             AnthropicLoop.run(%{
               base_url: "http://localhost:1234",
               model: "m",
               system: "s",
               user: "review",
               tools: Tools.for_scope(scope()),
               max_rounds: 5,
               post: post
             })

    assert text =~ "fail_open_authz"
    assert Agent.get(calls, & &1) == 2
  end

  test "at max_rounds, a final NO-TOOLS turn forces the model to conclude (investigation salvaged)" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    post = fn _u, _h, body, _r ->
      n = Agent.get_and_update(calls, &{&1, &1 + 1})

      # While there's a budget the model keeps calling tools; the FINAL turn must
      # arrive with NO tools key (forcing conclusion) — then it emits findings.
      if Map.has_key?(body, "tools") do
        {:ok,
         %{
           "stop_reason" => "tool_use",
           "content" => [
             %{"type" => "tool_use", "id" => "x#{n}", "name" => "list_files", "input" => %{}}
           ]
         }}
      else
        {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "[]"}]}}
      end
    end

    assert {:ok, "[]"} =
             AnthropicLoop.run(%{
               base_url: "http://localhost:1234",
               model: "m",
               system: "s",
               user: "u",
               tools: Tools.for_scope(scope()),
               max_rounds: 3,
               post: post
             })

    # 3 tool rounds (with tools) + 1 forced no-tools conclusion = 4 posts.
    assert Agent.get(calls, & &1) == 4
  end

  test "propagates an HTTP error" do
    failing = fn _u, _h, _b, _r -> {:error, :econnrefused} end

    assert {:error, :econnrefused} =
             AnthropicLoop.run(%{
               base_url: "http://localhost:1234",
               model: "m",
               system: "s",
               user: "u",
               tools: Tools.for_scope(scope()),
               post: failing
             })
  end
end
