defmodule Arbor.AI.Eval.Subjects.LLMRouterTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Eval.Subjects.LLMRouter

  setup do
    path = temp_path("router-index")
    File.write!(path, Jason.encode!(index_fixture()))
    on_exit(fn -> File.rm(path) end)
    %{index_path: path}
  end

  test "filters router selections against the index and returns JSON-clean output", %{
    index_path: index_path
  } do
    router_fn = fn base_url, model, system_prompt, user_prompt, timeout ->
      send(self(), {:route, base_url, model, system_prompt, user_prompt, timeout})

      {:ok,
       Jason.encode!(%{
         "selected" => [
           "Arbor.Actions.Shell",
           "Untrusted.Dynamic.Module",
           "Arbor.Actions.FileRead"
         ]
       })}
    end

    assert {:ok, result} =
             LLMRouter.run("run a command",
               index_path: index_path,
               model: "router-model",
               top_k: 2,
               max_desc_chars: 10,
               base_url: "http://router.test",
               timeout: 456,
               router_fn: router_fn
             )

    assert_receive {:route, "http://router.test", "router-model", system_prompt, "run a command",
                    456}

    assert system_prompt =~ "Arbor.Actions.FileRead: Read fi..."
    assert result.text == ~s(["Arbor.Actions.Shell","Arbor.Actions.FileRead"])

    assert result.retrieved == [
             %{module: "Arbor.Actions.Shell", score: nil},
             %{module: "Arbor.Actions.FileRead", score: nil}
           ]

    assert is_integer(result.duration_ms) and result.duration_ms >= 0
    assert {:ok, _json} = Jason.encode(result)
  end

  test "requires an explicit index path" do
    assert LLMRouter.run("run a command", model: "router-model") ==
             {:error, {:missing_option, :index_path}}
  end

  test "rejects malformed input and malformed model JSON without raising", %{
    index_path: index_path
  } do
    opts = [
      index_path: index_path,
      model: "router-model",
      router_fn: fn _, _, _, _, _ -> {:ok, "not-json"} end
    ]

    assert LLMRouter.run(%{"prompt" => []}, opts) ==
             {:error, {:invalid_input, :prompt_required}}

    assert LLMRouter.run("run a command", opts) ==
             {:error, {:invalid_router_response, :malformed_json}}
  end

  test "truncates multibyte descriptions at a UTF-8-safe byte ceiling", %{
    index_path: index_path
  } do
    index = index_fixture()
    [first | rest] = index["actions"]

    File.write!(
      index_path,
      Jason.encode!(%{index | "actions" => [%{first | "description" => "éééabc"} | rest]})
    )

    parent = self()

    assert {:ok, _result} =
             LLMRouter.run("run a command",
               index_path: index_path,
               model: "router-model",
               max_desc_chars: 7,
               router_fn: fn _, _, system_prompt, _, _ ->
                 send(parent, {:system_prompt, system_prompt})
                 {:ok, ~s({"selected":["Arbor.Actions.FileRead"]})}
               end
             )

    assert_receive {:system_prompt, system_prompt}
    assert String.valid?(system_prompt)
    assert system_prompt =~ "Arbor.Actions.FileRead: éé..."
    refute system_prompt =~ "ééé"
  end

  test "security regression: one combining grapheme cannot inflate the router prompt", %{
    index_path: index_path
  } do
    index = index_fixture()
    [first | rest] = index["actions"]
    combining_description = "a" <> String.duplicate("\u0301", 5_000)

    File.write!(
      index_path,
      Jason.encode!(%{
        index
        | "actions" => [%{first | "description" => combining_description} | rest]
      })
    )

    parent = self()

    assert {:ok, _result} =
             LLMRouter.run("run a command",
               index_path: index_path,
               model: "router-model",
               max_desc_chars: 32,
               router_fn: fn _, _, system_prompt, _, _ ->
                 send(parent, {:bounded_system_prompt, system_prompt})
                 {:ok, ~s({"selected":["Arbor.Actions.FileRead"]})}
               end
             )

    assert_receive {:bounded_system_prompt, system_prompt}
    assert byte_size(system_prompt) < 2_000
    assert String.valid?(system_prompt)
    refute system_prompt =~ combining_description
  end

  test "security regression: aggregate router prompts fail closed at the hard byte ceiling", %{
    index_path: index_path
  } do
    actions =
      Enum.map(1..260, fn index ->
        %{
          "module" => "Arbor.Actions.Large#{index}",
          "description" => String.duplicate("d", 4_096),
          "embeddings" => %{}
        }
      end)

    File.write!(index_path, Jason.encode!(%{"actions" => actions}))

    assert LLMRouter.run("run a command",
             index_path: index_path,
             model: "router-model",
             max_desc_chars: 4_096,
             router_fn: fn _, _, _, _, _ -> flunk("oversized prompt reached the router") end
           ) == {:error, {:router_prompt_size_exceeded, 1_048_576}}
  end

  test "propagates injected router errors and rejects malformed callback results", %{
    index_path: index_path
  } do
    base_opts = [index_path: index_path, model: "router-model"]

    assert LLMRouter.run(
             "run a command",
             Keyword.put(base_opts, :router_fn, fn _, _, _, _, _ -> {:error, :offline} end)
           ) == {:error, :offline}

    assert LLMRouter.run(
             "run a command",
             Keyword.put(base_opts, :router_fn, fn _, _, _, _, _ -> {:ok, %{}} end)
           ) == {:error, {:invalid_router_response, :binary_content_required}}
  end

  test "security regression: router content is byte bounded before JSON decoding", %{
    index_path: index_path
  } do
    oversized_content = <<255>> <> String.duplicate("x", 262_144)

    assert LLMRouter.run("run a command",
             index_path: index_path,
             model: "router-model",
             router_fn: fn _, _, _, _, _ -> {:ok, oversized_content} end
           ) ==
             {:error, {:invalid_router_response, {:content_size_exceeded, 262_144}}}
  end

  test "security regression: HTTP failures retain only a bounded body diagnostic", %{
    index_path: index_path
  } do
    parent = self()
    response_body = String.duplicate("x", 2_049) <> "sensitive-tail"

    install_req_adapter(fn request ->
      send(parent, {:router_http_request, request.url.path, decode_request_body(request)})

      response =
        Req.Response.new(
          status: 418,
          headers: %{"content-type" => ["text/plain"]},
          body: response_body
        )

      {request, response}
    end)

    assert {:error, {:router_http_error, 418, %{body_excerpt: excerpt, truncated: true}}} =
             LLMRouter.run("run a command",
               index_path: index_path,
               model: "router-model",
               timeout: 1_000
             )

    assert_receive {:router_http_request, "/api/chat", request_body}
    assert request_body["model"] == "router-model"
    assert byte_size(excerpt) == 2_048
    refute excerpt =~ "sensitive-tail"
  end

  test "default Ollama router transport posts to /api/chat", %{index_path: index_path} do
    parent = self()

    install_req_adapter(fn request ->
      body = decode_request_body(request)
      send(parent, {:router_success_request, request.url.path, body})

      response_body = %{
        "message" => %{
          "content" => ~s({"selected":["Arbor.Actions.Shell"]})
        }
      }

      {request, Req.Response.new(status: 200, body: response_body)}
    end)

    assert {:ok, result} =
             LLMRouter.run("run a command",
               index_path: index_path,
               model: "router-model",
               base_url: "http://ollama.test",
               timeout: 1_000
             )

    assert_receive {:router_success_request, "/api/chat", request_body}
    assert request_body["model"] == "router-model"
    assert request_body["stream"] == false
    assert result.text == ~s(["Arbor.Actions.Shell"])
  end

  test "default Ollama router transport rejects a malformed 200 response", %{
    index_path: index_path
  } do
    install_req_adapter(fn request ->
      malformed_body = %{"message" => %{"content" => %{}}}
      {request, Req.Response.new(status: 200, body: malformed_body)}
    end)

    assert {:error, {:router_http_error, 200, %{body_excerpt: excerpt, truncated: true}}} =
             LLMRouter.run("run a command",
               index_path: index_path,
               model: "router-model",
               base_url: "http://ollama.test"
             )

    assert excerpt =~ "message"
    refute excerpt =~ "#PID"
  end

  defp index_fixture do
    %{
      "actions" => [
        %{
          "module" => "Arbor.Actions.FileRead",
          "description" => "Read files from disk",
          "embeddings" => %{}
        },
        %{
          "module" => "Arbor.Actions.Shell",
          "description" => "Run shell commands",
          "embeddings" => %{}
        }
      ]
    }
  end

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "arbor-ai-#{label}-#{System.unique_integer([:positive, :monotonic])}.json"
    )
  end

  defp install_req_adapter(adapter) do
    previous_options = Req.default_options()
    on_exit(fn -> Req.default_options(previous_options) end)
    Req.default_options(adapter: adapter)
  end

  defp decode_request_body(request) do
    request.body
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end
end
