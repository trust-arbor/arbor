defmodule Arbor.LLM.Eval.SubjectTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM
  alias Arbor.LLM.{Client, Message, ProviderRegistry, Request, Response, StreamEvent}
  alias Arbor.LLM.Eval.Subject
  alias Arbor.LLM.TestSupport.TransportContract

  defmodule TestAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "eval_test"

    @impl true
    def complete(%Request{model: "transport-error"}, _opts) do
      {:error, {:transport_failed, 503}}
    end

    def complete(%Request{model: "huge-transport-error"}, _opts) do
      {:error, {:transport_failed, List.duplicate(String.duplicate("e", 2_000), 100_000)}}
    end

    def complete(%Request{model: "huge-empty-metadata"}, _opts) do
      {:ok,
       %Response{
         text: "",
         finish_reason: :stop,
         usage: %{output_tokens: :erlang.bsl(1, 1_000_000)},
         content_parts: List.duplicate(%{kind: String.duplicate("k", 2_000)}, 100_000),
         raw: %{}
       }}
    end

    def complete(%Request{model: "oversized-complete"}, _opts) do
      {:ok, %Response{text: "123456", usage: %{output_tokens: 2}, raw: %{}}}
    end

    def complete(%Request{model: "oversized-invalid-complete"}, _opts) do
      {:ok, %Response{text: <<255, 1, 2, 3, 4, 5>>, usage: %{}, raw: %{}}}
    end

    def complete(%Request{model: "slow-complete-deadline"}, _opts) do
      owner = Process.whereis(Arbor.LLM.Eval.SubjectTest.DeadlineProbe)
      send(owner, {:deadline_probe_started, self()})

      receive do
        {:release_complete, ^owner} ->
          send(owner, :late_complete_side_effect)
          {:ok, %Response{text: "late", usage: %{}, raw: %{}}}
      end
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
    def stream(%Request{model: model}, _opts) do
      case model do
        "stream-error" ->
          [
            %StreamEvent{type: :delta, data: %{"text" => "partial"}},
            %StreamEvent{type: :error, data: %{"reason" => "network"}}
          ]

        "unbounded-stream" ->
          Stream.repeatedly(fn -> %StreamEvent{type: :delta, data: %{text: "x"}} end)

        "active-stream" ->
          Stream.repeatedly(fn ->
            Process.sleep(5)
            %StreamEvent{type: :delta, data: %{text: "x"}}
          end)

        "terminal-stream" ->
          Stream.concat(
            [
              %StreamEvent{type: :delta, data: %{text: "done"}},
              %StreamEvent{type: :finish, data: %{"reason" => "stop"}}
            ],
            Stream.map([:after_finish], fn _ -> raise "stream consumed past finish" end)
          )

        "oversized-stream" ->
          [
            %StreamEvent{type: :delta, data: %{text: "1234"}},
            %StreamEvent{type: :delta, data: %{text: "56"}},
            %StreamEvent{type: :finish, data: %{}}
          ]

        "oversized-invalid-stream" ->
          [
            %StreamEvent{type: :delta, data: %{text: <<255, 1, 2, 3, 4, 5>>}},
            %StreamEvent{type: :finish, data: %{}}
          ]

        "ignored-metadata-stream" ->
          [
            %StreamEvent{
              type: :delta,
              data: %{metadata: String.duplicate("m", 2_000_000), text: ""}
            },
            %StreamEvent{type: :finish, data: %{}}
          ]

        _other ->
          [
            %StreamEvent{type: :start, data: %{}},
            %StreamEvent{type: :delta, data: %{"text" => "hel"}},
            %StreamEvent{type: :delta, data: %{text: "lo"}},
            %StreamEvent{type: :finish, data: %{"reason" => "stop"}}
          ]
      end
    end
  end

  defp client do
    Client.new()
    |> Client.register_adapter(TestAdapter)
  end

  defp stop_deadline_probe(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end

  describe "run/2" do
    test "uses an injected client and forwards request and transport options" do
      TransportContract.setup([
        TransportContract.route("eval_test", "test-model", :public, nil)
      ])

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

      decoded = Jason.decode!(text)

      assert Map.delete(decoded, "receive_timeout") == %{
               "max_tokens" => 1_234,
               "messages" => [
                 %{"content" => "Be precise", "role" => "system"},
                 %{"content" => "Hello", "role" => "user"}
               ],
               "model" => "test-model",
               "provider" => "eval_test",
               "temperature" => 0.25
             }

      # The transport timeout is the time left on the caller deadline.
      # Setup can consume a few milliseconds; it must not be widened.
      assert decoded["receive_timeout"] in 4_221..4_321
    end

    test "accepts string and atom-keyed inputs" do
      TransportContract.setup([
        TransportContract.route("eval_test", "model", :public, nil)
      ])

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

    test "leaves max_tokens unset unless the caller supplies it" do
      TransportContract.setup([
        TransportContract.route("eval_test", "model", :public, nil)
      ])

      assert {:ok, %{text: text}} =
               Subject.run("hello",
                 client: client(),
                 provider: "eval_test",
                 model: "model"
               )

      assert Jason.decode!(text)["max_tokens"] == nil
    end

    test "returns shaped errors for malformed input and options" do
      base_opts = [client: client(), provider: "eval_test", model: "model"]

      assert Subject.run(%{}, base_opts) == {:error, {:invalid_input, :prompt_required}}

      assert Subject.run(%{"prompt" => 42}, base_opts) ==
               {:error, {:invalid_input, :prompt_required}}

      assert Subject.run(%{"prompt" => "hello", "system" => []}, base_opts) ==
               {:error, {:invalid_input, :system_must_be_string}}

      assert Subject.run(:unsupported, base_opts) ==
               {:error, {:invalid_input, :prompt_required}}

      assert Subject.run("hello", %{}) == {:error, {:invalid_options, :keyword_required}}

      assert Subject.run("hello", [:not_a_keyword]) ==
               {:error, {:invalid_options, :keyword_required}}
    end

    test "security regression: ingress rejects oversized invalid UTF-8 by bytes first" do
      base_opts = [client: client(), provider: "eval_test", model: "model"]
      oversized_invalid = String.duplicate("p", 1_048_576) <> <<255>>

      assert Subject.run(oversized_invalid, base_opts) ==
               {:error, {:invalid_input, {:prompt_bytes_exceeded, 1_048_576}}}

      assert Subject.run(%{"prompt" => "ok", "system" => oversized_invalid}, base_opts) ==
               {:error, {:invalid_input, {:system_bytes_exceeded, 1_048_576}}}

      assert Subject.run(
               "ok",
               Keyword.put(base_opts, :provider, String.duplicate("x", 256) <> <<255>>)
             ) ==
               {:error, {:invalid_option, :provider, {:byte_size_exceeded, 256}}}
    end

    test "security regression: protocol numeric representations are bounded" do
      TransportContract.setup([
        TransportContract.route("eval_test", "model", :public, nil)
      ])

      base_opts = [client: client(), provider: "eval_test", model: "model"]
      huge_integer = :erlang.bsl(1, 1_000_000)

      assert Subject.run("hello", Keyword.put(base_opts, :max_tokens, 1_000_000)) |> elem(0) ==
               :ok

      assert Subject.run("hello", Keyword.put(base_opts, :max_tokens, huge_integer)) ==
               {:error,
                {:invalid_option, :max_tokens,
                 {:integer_range_required, 1, 9_223_372_036_854_775_807}}}

      assert Subject.run("hello", Keyword.put(base_opts, :temperature, huge_integer)) ==
               {:error,
                {:invalid_option, :temperature, {:finite_number_range_required, 0, 1.0e6}}}
    end

    test "returns shaped errors for invalid numeric limits" do
      base_opts = [client: client(), provider: "eval_test", model: "model"]

      cases = [
        {:max_tokens, nil, :positive_integer_required},
        {:max_tokens, 0, :positive_integer_required},
        {:max_tokens, 1.5, :positive_integer_required},
        {:timeout, 0, {:integer_range_required, 1, 900_000}},
        {:timeout, 900_001, {:integer_range_required, 1, 900_000}},
        {:max_stream_events, 100_001, {:integer_range_required, 1, 100_000}},
        {:max_output_bytes, -1, {:integer_range_required, 1, 16_777_216}}
      ]

      for {key, value, reason} <- cases do
        assert Subject.run("hello", Keyword.put(base_opts, key, value)) ==
                 {:error, {:invalid_option, key, reason}}
      end
    end

    test "collects native stream events from an injected transport" do
      TransportContract.setup([
        TransportContract.route("eval_test", "stream-model", :public, nil)
      ])

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

    test "security regression: stream error events fail the public subject" do
      TransportContract.setup([
        TransportContract.route("eval_test", "stream-error", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "stream-error",
               stream: true
             ) == {:error, {:stream_error, "network"}}
    end

    test "security regression: an unbounded active stream hits the hard event ceiling" do
      TransportContract.setup([
        TransportContract.route("eval_test", "unbounded-stream", :public, nil)
      ])

      task =
        Task.async(fn ->
          Subject.run("hello",
            client: client(),
            provider: "eval_test",
            model: "unbounded-stream",
            stream: true,
            timeout: 5_000,
            max_stream_events: 8
          )
        end)

      result =
        case Task.yield(task, 1_000) do
          {:ok, result} ->
            result

          nil ->
            Task.shutdown(task, :brutal_kill)
            :did_not_terminate
        end

      assert result ==
               {:error, {:stream_collection_failed, {:stream_limit_exceeded, :events, 8}}}
    end

    test "enforces an absolute elapsed deadline on a continuously active stream" do
      TransportContract.setup([
        TransportContract.route("eval_test", "active-stream", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "active-stream",
               stream: true,
               timeout: 25
             ) == {:error, {:stream_deadline_exceeded, 25}}
    end

    test "security regression: timed out streams leave no late owner-stamped replies" do
      TransportContract.setup([
        TransportContract.route("eval_test", "active-stream", :public, nil)
      ])

      for _ <- 1..10 do
        assert Subject.run("hello",
                 client: client(),
                 provider: "eval_test",
                 model: "active-stream",
                 stream: true,
                 timeout: 10
               ) == {:error, {:stream_deadline_exceeded, 10}}
      end

      Process.sleep(30)
      {:messages, messages} = Process.info(self(), :messages)

      refute Enum.any?(messages, fn
               {ref, kind, _value, _completed_mono}
               when is_reference(ref) and
                      kind in [:event, :done, :stream_error, :producer_error] ->
                 true

               _other ->
                 false
             end)
    end

    test "security regression: nonstreaming adapters share one owned absolute deadline" do
      TransportContract.setup([
        TransportContract.route("eval_test", "slow-complete-deadline", :public, nil)
      ])

      Process.register(self(), Arbor.LLM.Eval.SubjectTest.DeadlineProbe)

      on_exit(fn ->
        if Process.whereis(Arbor.LLM.Eval.SubjectTest.DeadlineProbe) == self(),
          do: Process.unregister(Arbor.LLM.Eval.SubjectTest.DeadlineProbe)
      end)

      owner = self()
      run_ref = make_ref()
      started = System.monotonic_time(:millisecond)

      {runner, runner_monitor} =
        spawn_monitor(fn ->
          result =
            Subject.run("hello",
              client: client(),
              provider: "eval_test",
              model: "slow-complete-deadline",
              timeout: 50
            )

          send(owner, {run_ref, result})
        end)

      on_exit(fn -> stop_deadline_probe(runner) end)
      assert_receive {:deadline_probe_started, worker}, 1_000
      on_exit(fn -> stop_deadline_probe(worker) end)
      worker_monitor = Process.monitor(worker)

      assert_receive {^run_ref, result}, 1_000
      assert result == {:error, {:request_deadline_exceeded, 50}}

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 40

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, reason}, 1_000
      assert reason in [:killed, :noproc]
      assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000

      send(worker, {:release_complete, owner})
      refute_receive :late_complete_side_effect, 250
    end

    test "security regression: terminal stream events stop producer consumption" do
      TransportContract.setup([
        TransportContract.route("eval_test", "terminal-stream", :public, nil)
      ])

      assert {:ok, %{text: "done"}} =
               Subject.run("hello",
                 client: client(),
                 provider: "eval_test",
                 model: "terminal-stream",
                 stream: true
               )
    end

    test "security regression: streaming output obeys the caller byte ceiling" do
      TransportContract.setup([
        TransportContract.route("eval_test", "oversized-stream", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "oversized-stream",
               stream: true,
               max_output_bytes: 5
             ) ==
               {:error,
                {:stream_collection_failed,
                 {:invalid_stream_event, {:decoded_term_limit_exceeded, :bytes, 5}}}}
    end

    test "security regression: complete output obeys the caller byte ceiling" do
      TransportContract.setup([
        TransportContract.route("eval_test", "oversized-complete", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "oversized-complete",
               max_output_bytes: 5
             ) ==
               {:error, {:invalid_completion_response, {:text, :bounded_string_required, 5}}}
    end

    test "security regression: invalid UTF-8 complete output fails closed" do
      TransportContract.setup([
        TransportContract.route("eval_test", "oversized-invalid-complete", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "oversized-invalid-complete",
               max_output_bytes: 5
             ) ==
               {:error, {:invalid_completion_response, {:text, :bounded_string_required, 5}}}
    end

    test "security regression: invalid UTF-8 stream chunks fail closed" do
      TransportContract.setup([
        TransportContract.route("eval_test", "oversized-invalid-stream", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "oversized-invalid-stream",
               stream: true,
               max_output_bytes: 5
             ) ==
               {:error,
                {:stream_collection_failed,
                 {:invalid_stream_event, {:decoded_term_limit_exceeded, :bytes, 5}}}}
    end

    test "security regression: ignored stream metadata hits bytes before event count" do
      TransportContract.setup([
        TransportContract.route("eval_test", "ignored-metadata-stream", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "ignored-metadata-stream",
               stream: true,
               max_stream_events: 1
             ) ==
               {:error,
                {:stream_collection_failed,
                 {:invalid_stream_event, {:decoded_term_limit_exceeded, :bytes, 1_048_576}}}}
    end

    test "preserves transport error reasons and shapes invalid client errors" do
      TransportContract.setup([
        TransportContract.route("eval_test", "transport-error", :public, nil)
      ])

      assert Subject.run("hello",
               client: client(),
               provider: "eval_test",
               model: "transport-error"
             ) == {:error, {:transport_failed, 503}}

      assert Subject.run("hello", client: TestAdapter, provider: "eval_test") ==
               {:error, "invalid client: expected an Arbor.LLM.Client struct"}
    end

    test "security regression: huge external errors and empty metadata are bounded" do
      TransportContract.setup([
        TransportContract.route("eval_test", "huge-transport-error", :public, nil),
        TransportContract.route("eval_test", "huge-empty-metadata", :public, nil)
      ])

      assert {:error, {:invalid_adapter_error, :transport_failed}} =
               Subject.run("hello",
                 client: client(),
                 provider: "eval_test",
                 model: "huge-transport-error"
               )

      task =
        Task.async(fn ->
          Subject.run("hello",
            client: client(),
            provider: "eval_test",
            model: "huge-empty-metadata"
          )
        end)

      assert {:ok,
              {:error,
               {:invalid_completion_response, {:decoded_term_invalid, :signed_64_required}}}} =
               Task.yield(task, 1_000)
    end

    test "preserves the catalog-backed unknown provider error shape" do
      assert {:error, message} =
               Subject.run("hello", provider: "definitely_not_an_llm_provider")

      assert message =~ "unknown provider: definitely_not_an_llm_provider"
      assert message =~ "Available:"
    end

    test "security regression: non-ready exact OAuth route fails before transport" do
      previous = Application.fetch_env(:arbor_llm, :oauth_store_dir)

      store_dir =
        Path.join(
          System.tmp_dir!(),
          "arbor-eval-subject-oauth-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(store_dir)
      Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_llm, :oauth_store_dir, value)
          :error -> Application.delete_env(:arbor_llm, :oauth_store_dir)
        end

        File.rm_rf!(store_dir)
      end)

      assert Subject.run("hello", provider: "xai_oauth", model: "grok-4.5") ==
               {:error,
                {:eval_provider_unavailable, "xai_oauth", {:oauth_status, "login_required"}}}
    end

    test "returns JSON-clean successful output" do
      TransportContract.setup([
        TransportContract.route("eval_test", "json-model", :public, nil)
      ])

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

    test "uses the catalog-backed default HTTP transport without an implicit max_tokens" do
      TransportContract.setup([
        TransportContract.route(
          "lm_studio",
          "catalog-model",
          :public,
          ProviderRegistry.default_base_url("lm_studio")
        )
      ])

      previous_options = Req.default_options()
      parent = self()

      on_exit(fn -> Req.default_options(previous_options) end)

      Req.default_options(
        adapter: fn request ->
          body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
          send(parent, {:default_transport_request, request.url.path, body})

          response_body =
            Jason.encode!(%{
              "choices" => [
                %{
                  "finish_reason" => "stop",
                  "message" => %{"content" => "catalog response", "role" => "assistant"}
                }
              ],
              "usage" => %{"completion_tokens" => 2}
            })

          response =
            Req.Response.new(
              status: 200,
              headers: %{"content-type" => ["application/json"]},
              body: response_body
            )

          {request, response}
        end
      )

      assert {:ok, %{text: "catalog response", provider: "lm_studio"}} =
               Subject.run("hello",
                 provider: "lm_studio",
                 model: "catalog-model",
                 timeout: 1_000
               )

      assert_receive {:default_transport_request, "/v1/chat/completions", request_body}
      refute Map.has_key?(request_body, "max_tokens")
      assert request_body["model"] == "catalog-model"
    end

    @tag :llm_local
    test "keeps the tagged local catalog transport smoke boundary" do
      result = Subject.run("hello", provider: "lm_studio", model: "", timeout: 100)

      assert match?({:ok, %{text: text}} when is_binary(text), result) or
               match?({:error, _reason}, result)
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

    test "exposes the closed symbolic subject catalog names" do
      assert LLM.eval_subject_names() == ["llm"]
    end

    test "unknown strings do not intern atoms or resolve modules" do
      unknown = "unknown_eval_#{System.unique_integer([:positive, :monotonic])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
      assert LLM.eval_subject(unknown) == nil
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end
end
