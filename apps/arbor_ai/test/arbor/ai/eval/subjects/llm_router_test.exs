defmodule Arbor.AI.Eval.Subjects.LLMRouterTest do
  use ExUnit.Case, async: true

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

    assert system_prompt =~ "Arbor.Actions.FileRead: Read files..."
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

  test "truncates multibyte descriptions by UTF-8 characters", %{index_path: index_path} do
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
               max_desc_chars: 2,
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
end
