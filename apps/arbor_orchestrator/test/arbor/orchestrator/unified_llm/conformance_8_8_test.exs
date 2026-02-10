defmodule Arbor.Orchestrator.UnifiedLLM.Conformance88Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.{
    Client,
    Message,
    ProviderError,
    Request,
    Retry,
    StreamEvent
  }

  defmodule ErrorAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "error-adapter"

    @impl true
    def complete(_request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, :complete_called)

      {:error,
       ProviderError.exception(
         message: "unauthorized",
         provider: "error-adapter",
         status: 401,
         retryable: false
       )}
    end

    @impl true
    def stream(_request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, :stream_called)

      [
        %StreamEvent{type: :start, data: %{}},
        %StreamEvent{type: :delta, data: %{"text" => "partial"}},
        %StreamEvent{type: :error, data: %{"reason" => "network"}}
      ]
    end
  end

  test "8.8 Retry.execute respects retry-after when within max_delay" do
    parent = self()

    fun = fn ->
      send(parent, :attempt)

      case Process.get(:retry_after_calls, 0) do
        0 ->
          Process.put(:retry_after_calls, 1)

          {:error,
           ProviderError.exception(
             message: "rate limited",
             provider: "openai",
             status: 429,
             retryable: true,
             retry_after_ms: 5
           )}

        _ ->
          {:ok, :ok}
      end
    end

    assert {:ok, :ok} =
             Retry.execute(fun,
               max_retries: 2,
               max_delay_ms: 50,
               sleep_fn: fn _ -> :ok end
             )

    assert_receive :attempt
    assert_receive :attempt
  end

  test "8.8 Retry.execute does not retry when retry-after exceeds max_delay" do
    parent = self()

    fun = fn ->
      send(parent, :attempt)

      {:error,
       ProviderError.exception(
         message: "rate limited",
         provider: "openai",
         status: 429,
         retryable: true,
         retry_after_ms: 90_000
       )}
    end

    assert {:error, %ProviderError{status: 429}} =
             Retry.execute(fun, max_retries: 2, max_delay_ms: 1_000, sleep_fn: fn _ -> :ok end)

    assert_receive :attempt
    refute_receive :attempt
  end

  test "8.8 low-level client.complete does not retry non-retryable errors automatically" do
    client =
      Client.new(default_provider: "error-adapter") |> Client.register_adapter(ErrorAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "hi")]}

    assert {:error, %ProviderError{status: 401, retryable: false}} =
             Client.complete(client, request, parent: self())

    assert_receive :complete_called
    refute_receive :complete_called
  end

  test "8.8 low-level client.stream does not retry after partial data" do
    client =
      Client.new(default_provider: "error-adapter") |> Client.register_adapter(ErrorAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "hi")]}

    assert {:ok, events} = Client.stream(client, request, parent: self())
    assert Enum.any?(events, &match?(%StreamEvent{type: :delta}, &1))
    assert Enum.any?(events, &match?(%StreamEvent{type: :error}, &1))
    assert_receive :stream_called
    refute_receive :stream_called
  end
end
