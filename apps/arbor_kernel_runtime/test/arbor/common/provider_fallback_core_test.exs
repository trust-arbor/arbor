defmodule Arbor.Common.ProviderFallbackCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Common.ProviderFallbackCore, as: Core

  @generic [{"openai_oauth", "gpt-5.6-sol"}, {"xai_oauth", "grok-4.6"}]

  defp avail(list), do: fn p -> p in list end

  test "an available preferred provider is kept as-is" do
    assert {:ok, {"ollama", "glm-5.2:cloud"}, :preferred} =
             Core.resolve("ollama", "glm-5.2:cloud", avail(["ollama"]), %{}, @generic)
  end

  test "an unavailable provider falls back to the first available generic candidate" do
    assert {:ok, {"xai_oauth", "grok-4.6"}, {:fallback, "ollama"}} =
             Core.resolve("ollama", "glm-5.2:cloud", avail(["xai_oauth"]), %{}, @generic)
  end

  test "a provider-specific chain is tried before the generic list" do
    specific = %{"ollama" => [{"openrouter", "z-ai/glm-5.2"}]}

    assert {:ok, {"openrouter", "z-ai/glm-5.2"}, {:fallback, "ollama"}} =
             Core.resolve(
               "ollama",
               "glm-5.2:cloud",
               avail(["openrouter", "openai_oauth"]),
               specific,
               @generic
             )
  end

  test "no available candidate reports the chain that was tried" do
    assert {:error, :no_available_provider, ["openai_oauth", "xai_oauth"]} =
             Core.resolve("ollama", "glm-5.2:cloud", avail([]), %{}, @generic)
  end

  test "the preferred provider is never its own fallback" do
    generic = [{"ollama", "other"}, {"xai_oauth", "grok-4.6"}]

    assert {:ok, {"xai_oauth", "grok-4.6"}, {:fallback, "ollama"}} =
             Core.resolve("ollama", "glm-5.2:cloud", avail(["xai_oauth"]), %{}, generic)
  end

  test "a nil provider (session default) is left alone" do
    assert {:ok, {nil, nil}, :preferred} = Core.resolve(nil, nil, avail([]), %{}, @generic)
  end

  test "a raising availability predicate fails closed to unavailable" do
    boom = fn _ -> raise "down" end
    assert {:error, :no_available_provider, _} = Core.resolve("ollama", "m", boom, %{}, @generic)
  end

  test "normalize_config accepts tuples, lists, maps, atom keys and drops junk" do
    {specific, generic} =
      Core.normalize_config(
        %{
          ollama: [
            ["openrouter", "m1"],
            %{"provider" => "xai_oauth", "model" => "grok-4.6"},
            :junk
          ]
        },
        [{"openai_oauth", "gpt-5.6-sol"}, {"", "x"}, nil, [:xai_oauth, "grok-4.6"]]
      )

    assert specific == %{"ollama" => [{"openrouter", "m1"}, {"xai_oauth", "grok-4.6"}]}
    assert generic == [{"openai_oauth", "gpt-5.6-sol"}, {"xai_oauth", "grok-4.6"}]
    assert Core.normalize_config(nil, nil) == {%{}, []}
  end
end
