defmodule Arbor.LLM.ProviderClientConfigurationTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM
  alias Arbor.LLM.{Client, Response, StreamEvent}

  @moduletag :fast
  @provider "provider_client_configuration_fixture"

  defmodule FirstAdapter do
    def complete(_request, _opts), do: {:ok, %Response{text: "First complete café"}}

    def stream(_request, _opts) do
      [
        %StreamEvent{type: :delta, data: %{text: "First café "}},
        %StreamEvent{type: :delta, data: %{text: "東京"}},
        %StreamEvent{type: :finish, data: %{reason: :stop}}
      ]
    end
  end

  defmodule ReplacementAdapter do
    def stream(_request, _opts),
      do: [%StreamEvent{type: :delta, data: %{text: "Replacement 東京"}}]
  end

  setup do
    # Same-library custody only: preserve the optional cached client without
    # triggering environment discovery or touching any credential source.
    previous = :persistent_term.get({Client, :default_client}, nil)

    on_exit(fn ->
      if previous,
        do: Client.set_default_client(previous),
        else: LLM.clear_provider_client()
    end)

    :ok
  end

  test "public host configuration drives generate and Unicode stream through the selected adapter and middleware" do
    observer = self()

    middleware = fn request, next ->
      send(observer, {:configured_middleware, request.model})
      next.(request)
    end

    stream_middleware = fn request, next ->
      send(observer, {:configured_stream_middleware, request.model})
      next.(request)
    end

    catalog = %{@provider => [%{id: "fixture-model", modalities: [:text]}]}

    assert :ok =
             LLM.configure_provider_client(
               adapters: %{@provider => FirstAdapter},
               default_provider: @provider,
               model_catalog: catalog,
               middleware: [middleware],
               stream_middleware: [stream_middleware]
             )

    assert {:ok, response} = LLM.generate(model: "fixture-model", prompt: "ordinary message")
    assert response.text == "First complete café"
    assert_receive {:configured_middleware, "fixture-model"}
    assert streamed_text() == "First café 東京"
    assert_receive {:configured_stream_middleware, "fixture-model"}
    assert Client.list_models(Client.default_client()) == catalog[@provider]
  end

  test "malformed configuration preserves the active client and does not run configuration functions" do
    assert :ok =
             LLM.configure_provider_client(
               adapters: %{@provider => FirstAdapter},
               default_provider: @provider
             )

    observer = self()
    invalid_arity = fn -> send(observer, :invalid_configuration_function_ran) end

    invalid = [
      nil,
      %{},
      [{"adapters", %{}}],
      [:not_a_keyword],
      [{:adapters, %{}} | :improper],
      [unknown: true],
      [default_provider: @provider, default_provider: "replacement"],
      [adapters: []],
      [adapters: %{42 => FirstAdapter}],
      [adapters: %{@provider => "Elixir.UntrustedAdapter"}],
      [adapters: %{@provider => nil}],
      [adapters: %{<<255>> => FirstAdapter}],
      [default_provider: :provider],
      [default_provider: <<255>>],
      [model_catalog: :other],
      [model_catalog: %{42 => []}],
      [model_catalog: %{@provider => :not_models}],
      [model_catalog: %{@provider => [%{} | :improper]}],
      [middleware: [invalid_arity]],
      [middleware: [:not_a_function]],
      [stream_middleware: [fn _request, next -> next end | :improper]]
    ]

    for config <- invalid do
      assert {:error, :invalid_provider_client_config} = LLM.configure_provider_client(config)
      assert streamed_text() == "First café 東京"
    end

    refute_receive :invalid_configuration_function_ran
  end

  test "clear removes the configured client, is idempotent and resumes the existing lazy factory" do
    assert :ok =
             LLM.configure_provider_client(
               adapters: %{@provider => FirstAdapter},
               default_provider: @provider
             )

    assert streamed_text() == "First café 東京"
    assert :ok = LLM.clear_provider_client()
    assert :ok = LLM.clear_provider_client()

    # Exercise the existing same-library public lazy factory with discovery
    # explicitly disabled. No provider/credential probing is needed to prove
    # that clear removed the previously selected adapter.
    Client.default_client(
      adapters: %{@provider => ReplacementAdapter},
      default_provider: @provider,
      discover_local: false,
      discover_oauth: false,
      discover_acp: false,
      discover_keyless: false
    )

    assert streamed_text() == "Replacement 東京"
  end

  test "constructor defaults and existing optional shapes remain valid host configuration" do
    assert :ok = LLM.configure_provider_client([])
    assert :ok = LLM.configure_provider_client(default_provider: nil, model_catalog: :llmdb)
    assert :ok = LLM.configure_provider_client(adapters: %{}, model_catalog: %{}, middleware: [])
    assert :ok = LLM.clear_provider_client()
  end

  defp streamed_text do
    assert {:ok, events} = LLM.stream(model: "fixture-model", prompt: "ordinary message")

    events
    |> Enum.flat_map(fn
      %StreamEvent{type: :delta, data: %{text: text}} -> [text]
      %StreamEvent{type: :delta, data: %{"text" => text}} -> [text]
      %StreamEvent{type: :finish} -> []
    end)
    |> Enum.join()
  end
end
