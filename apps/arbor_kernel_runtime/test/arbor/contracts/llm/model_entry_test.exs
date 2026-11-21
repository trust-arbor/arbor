defmodule Arbor.Contracts.LLM.ModelEntryTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

  describe "ProviderEntry.new/1" do
    test "builds a complete entry from attrs" do
      assert {:ok, %ProviderEntry{} = p} =
               ProviderEntry.new(%{
                 id: :anthropic_direct,
                 ref: "claude-opus-4-6",
                 auth: :api_key,
                 runtimes: [:arbor],
                 pricing: %{input_per_mtok: 15.0, output_per_mtok: 75.0}
               })

      assert p.id == :anthropic_direct
      assert p.ref == "claude-opus-4-6"
      assert p.auth == :api_key
      assert p.runtimes == [:arbor]
      assert p.pricing == %{input_per_mtok: 15.0, output_per_mtok: 75.0}
    end

    test "pricing is optional" do
      assert {:ok, %ProviderEntry{pricing: nil}} =
               ProviderEntry.new(%{
                 id: :openrouter,
                 ref: "anthropic/claude-opus-4-6",
                 auth: :api_key,
                 runtimes: [:arbor]
               })
    end

    test "all five auth values accepted" do
      for auth <- [:api_key, :oauth, :aws, :gcp, :none] do
        assert {:ok, %ProviderEntry{auth: ^auth}} =
                 ProviderEntry.new(%{id: :p, ref: "r", auth: auth, runtimes: [:arbor]})
      end
    end

    test "rejects unknown auth value" do
      assert {:error, {:invalid_auth, :guess}} =
               ProviderEntry.new(%{id: :p, ref: "r", auth: :guess, runtimes: [:arbor]})
    end

    test "requires non-empty runtimes list" do
      assert {:error, :runtimes_required} =
               ProviderEntry.new(%{id: :p, ref: "r", auth: :api_key, runtimes: []})

      assert {:error, :runtimes_required} =
               ProviderEntry.new(%{id: :p, ref: "r", auth: :api_key})
    end

    test "rejects non-atom runtimes" do
      assert {:error, {:invalid_runtimes, _}} =
               ProviderEntry.new(%{id: :p, ref: "r", auth: :api_key, runtimes: ["arbor"]})
    end

    test "requires id to be an atom" do
      assert {:error, {:missing_or_invalid, :id}} =
               ProviderEntry.new(%{id: "p", ref: "r", auth: :api_key, runtimes: [:arbor]})
    end

    test "accepts string keys (from JSON config)" do
      assert {:ok, %ProviderEntry{id: :openai}} =
               ProviderEntry.new(%{
                 "id" => :openai,
                 "ref" => "gpt-5",
                 "auth" => :api_key,
                 "runtimes" => [:arbor]
               })
    end
  end

  describe "ModelEntry.new/1" do
    @valid_attrs %{
      canonical_id: "claude-opus-4-6",
      family: :claude,
      context_window: 200_000,
      max_output_tokens: 32_000,
      providers: [
        %{id: :anthropic_direct, ref: "claude-opus-4-6", auth: :api_key, runtimes: [:arbor]}
      ]
    }

    test "builds a complete entry from attrs, coercing provider maps" do
      assert {:ok, %ModelEntry{} = e} = ModelEntry.new(@valid_attrs)

      assert e.canonical_id == "claude-opus-4-6"
      assert e.family == :claude
      assert e.context_window == 200_000
      assert e.max_output_tokens == 32_000
      assert e.effective_window_pct == 0.75
      assert e.capabilities == []
      assert e.caveats == []

      assert [%ProviderEntry{id: :anthropic_direct}] = e.providers
    end

    test "accepts pre-built ProviderEntry structs in providers list" do
      {:ok, p} =
        ProviderEntry.new(%{id: :openai, ref: "gpt-5", auth: :api_key, runtimes: [:arbor]})

      assert {:ok, %ModelEntry{providers: [^p]}} =
               ModelEntry.new(%{@valid_attrs | providers: [p]})
    end

    test "rejects empty providers list" do
      assert {:error, :providers_required} =
               ModelEntry.new(%{@valid_attrs | providers: []})
    end

    test "rejects invalid provider in list" do
      assert {:error, {:invalid_provider, _}} =
               ModelEntry.new(%{@valid_attrs | providers: [%{id: :x}]})
    end

    test "requires positive context_window" do
      assert {:error, {:missing_or_invalid, :context_window}} =
               ModelEntry.new(%{@valid_attrs | context_window: 0})

      assert {:error, {:missing_or_invalid, :context_window}} =
               ModelEntry.new(%{@valid_attrs | context_window: -1})
    end

    test "defaults effective_window_pct / capabilities / caveats" do
      assert {:ok, %ModelEntry{effective_window_pct: 0.75, capabilities: [], caveats: []}} =
               ModelEntry.new(@valid_attrs)
    end
  end

  describe "ModelEntry helpers" do
    setup do
      {:ok, entry} =
        ModelEntry.new(%{
          canonical_id: "claude-sonnet-4-6",
          family: :claude,
          context_window: 200_000,
          max_output_tokens: 64_000,
          capabilities: [:tool_use, :vision, :prompt_cache],
          providers: [
            %{
              id: :anthropic_direct,
              ref: "claude-sonnet-4-6",
              auth: :api_key,
              runtimes: [:arbor]
            },
            %{
              id: :openrouter,
              ref: "anthropic/claude-sonnet-4-6",
              auth: :api_key,
              runtimes: [:arbor]
            }
          ]
        })

      {:ok, entry: entry}
    end

    test "effective_window/1 = context_window * pct", %{entry: e} do
      assert ModelEntry.effective_window(e) == 150_000
    end

    test "capable?/2 true for declared capability", %{entry: e} do
      assert ModelEntry.capable?(e, :tool_use)
      assert ModelEntry.capable?(e, :vision)
    end

    test "capable?/2 false for undeclared", %{entry: e} do
      refute ModelEntry.capable?(e, :embedding)
      refute ModelEntry.capable?(e, :extended_thinking)
    end

    test "provider/2 finds by id", %{entry: e} do
      assert %ProviderEntry{id: :anthropic_direct} = ModelEntry.provider(e, :anthropic_direct)
      assert %ProviderEntry{id: :openrouter} = ModelEntry.provider(e, :openrouter)
      assert nil == ModelEntry.provider(e, :bedrock)
    end
  end
end
