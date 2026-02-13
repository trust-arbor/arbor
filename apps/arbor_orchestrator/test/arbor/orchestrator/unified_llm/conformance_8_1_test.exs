defmodule Arbor.Orchestrator.UnifiedLLM.Conformance81Test do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.UnifiedLLM.{Client, ConfigurationError, Request, Response}

  defmodule Conformance81Adapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "conformance81"

    @impl true
    def complete(%Request{} = request, _opts) do
      {:ok, %Response{text: "ok:" <> request.model, finish_reason: :stop, raw: %{}}}
    end
  end

  test "8.1 from_env raises when neither default provider nor provider credentials exist" do
    with_env(
      %{
        "UNIFIED_LLM_DEFAULT_PROVIDER" => nil,
        "OPENAI_API_KEY" => nil,
        "ANTHROPIC_API_KEY" => nil,
        "GEMINI_API_KEY" => nil
      },
      fn ->
        assert_raise ConfigurationError, fn ->
          Client.from_env(discover_cli: false, discover_local: false)
        end
      end
    )
  end

  test "8.1 supports default client storage and model catalog inspection" do
    :ok = Client.clear_default_client()
    on_exit(fn -> Client.clear_default_client() end)

    client =
      Client.new(default_provider: "conformance81")
      |> Client.register_adapter(Conformance81Adapter)

    assert :ok = Client.set_default_client(client)
    assert %Client{default_provider: "conformance81"} = Client.default_client()

    models = Client.list_models(client)
    assert Enum.any?(models, &(&1.id == "gpt-5"))
    assert {:ok, info} = Client.get_model_info(client, "gpt-5")
    assert info.family == "gpt-5"
  end

  test "8.1 complete middleware wraps adapter calls in declared order" do
    middleware = fn req, next ->
      req = %{req | model: req.model <> "-mw"}
      next.(req)
    end

    client =
      Client.new(default_provider: "conformance81", middleware: [middleware])
      |> Client.register_adapter(Conformance81Adapter)

    request = %Request{provider: "conformance81", model: "demo", messages: []}
    assert {:ok, response} = Client.complete(client, request)
    assert response.text == "ok:demo-mw"
  end

  defp with_env(overrides, fun) do
    keys = Map.keys(overrides)
    previous = Enum.into(keys, %{}, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn {key, value} ->
        if value == nil, do: System.delete_env(key), else: System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(previous, fn {key, value} ->
        if value == nil, do: System.delete_env(key), else: System.put_env(key, value)
      end)
    end
  end
end
