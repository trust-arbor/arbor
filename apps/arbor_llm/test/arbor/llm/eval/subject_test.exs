defmodule Arbor.LLM.Eval.SubjectTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM
  alias Arbor.LLM.{Client, Message, Request, Response, StreamEvent}
  alias Arbor.LLM.Eval.Subject

  defmodule TestAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "eval_test"

    @impl true
    def complete(%Request{model: "transport-error"}, _opts) do
      {:error, {:transport_failed, 503}}
    end

    def complete(%Request{} = request, opts) do
      payload = %{
        "max_tokens" => request.max_tokens,
        "messages" =>
          Enum.map(request.messages, fn message ->
            %{
              "content" => Message.text(message),
              "role" => Atom.to_string(message.role)
            }
          end),
        "model" => request.model,
        "provider" => request.provider,
        "receive_timeout" => opts[:receive_timeout],
        "temperature" => request.temperature
      }

      {:ok,
       %Response{
         text: Jason.encode!(payload),
         usage: %{output_tokens: 17},
         raw: %{}
       }}
    end

    @impl true
    def stream(%Request{}, _opts) do
      [
        %StreamEvent{type: :start, data: %{}},
        %StreamEvent{type: :delta, data: %{"text" => "hel"}},
        %StreamEvent{type: :delta, data: %{text: "lo"}},
        %StreamEvent{type: :finish, data: %{"reason" => "stop"}}
      ]
    end
  end

  defp client do
    Client.new()
    |> Client.register_adapter(TestAdapter)
  end

  describe "run/2" do
    test "uses an injected client and forwards request and transport options" do
      assert {:ok, output} =
               Subject.run(
                 %{"prompt" => "Hello", "system" => "Be precise"},
                 client: client(),
                 provider: "eval_test",
                 model: "test-model",
                 max_tokens: 1_234,
                 temperature: 0.25,
                 timeout: 4_321
               )

      assert %{
               text: text,
               duration_ms: duration_ms,
               ttft_ms: nil,
               tokens_generated: 17,
               model: "test-model",
               provider: "eval_test"
             } = output

      assert duration_ms >= 0

      assert Jason.decode!(text) == %{
               "max_tokens" => 1_234,
               "messages" => [
                 %{"content" => "Be precise", "role" => "system"},
                 %{"content" => "Hello", "role" => "user"}
               ],
               "model" => "test-model",
               "provider" => "eval_test",
               "receive_timeout" => 4_321,
               "temperature" => 0.25
             }
    end

    test "accepts string and atom-keyed inputs" do
      assert {:ok, %{text: string_text}} =
               Subject.run("hello", client: client(), provider: "eval_test", model: "model")

      assert Jason.decode!(string_text)["messages"] == [
               %{"content" => "hello", "role" => "user"}
             ]

      assert {:ok, %{text: map_text}} =
               Subject.run(%{prompt: "hello", system: "rules"},
                 client: client(),
                 provider: "eval_test",
                 model: "model"
               )

      assert Jason.decode!(map_text)["messages"] == [
               %{"content" => "rules", "role" => "system"},
               %{"content" => "hello", "role" => "user"}
             ]
    end

    test "collects native stream events from an injected transport" do
      assert {:ok, output} =
               Subject.run("hello",
                 client: client(),
                 provider: "eval_test",
                 model: "stream-model",
                 stream: true
               )

      assert output.text == "hello"
      assert output.tokens_generated == 1
      assert is_integer(output.ttft_ms)
      assert output.ttft_ms >= 0
      assert output.duration_ms >= output.ttft_ms
    end

    test "preserves transport error reasons and shapes invalid client errors" do
      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "transport-error"
             ) == {:error, {:transport_failed, 503}}

      assert Subject.run("hello", client: TestAdapter, provider: "eval_test") ==
               {:error, "invalid client: expected an Arbor.LLM.Client struct"}
    end

    test "preserves the catalog-backed unknown provider error shape" do
      assert {:error, message} =
               Subject.run("hello", provider: "definitely_not_an_llm_provider")

      assert message =~ "unknown provider: definitely_not_an_llm_provider"
      assert message =~ "Available:"
    end

    test "returns JSON-clean successful output" do
      assert {:ok, output} =
               Subject.run("hello",
                 client: client(),
                 provider: "eval_test",
                 model: "json-model"
               )

      assert {:ok, encoded} = Jason.encode(output)

      assert %{
               "duration_ms" => duration_ms,
               "model" => "json-model",
               "provider" => "eval_test",
               "text" => text,
               "tokens_generated" => 17,
               "ttft_ms" => nil
             } = Jason.decode!(encoded)

      assert is_integer(duration_ms)
      assert is_binary(text)
    end
  end

  describe "Arbor.LLM.eval_subject/1" do
    test "resolves only the exact symbolic LLM name" do
      assert LLM.eval_subject("llm") == Subject
      assert LLM.eval_subject("LLM") == nil
      assert LLM.eval_subject("Elixir.Arbor.LLM.Eval.Subject") == nil
      assert LLM.eval_subject(:llm) == nil
      assert LLM.eval_subject(nil) == nil
    end

    test "unknown strings do not intern atoms or resolve modules" do
      unknown = "unknown_eval_#{System.unique_integer([:positive, :monotonic])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
      assert LLM.eval_subject(unknown) == nil
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end
end
