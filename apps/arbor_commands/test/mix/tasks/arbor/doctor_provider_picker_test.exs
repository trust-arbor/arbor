defmodule Mix.Tasks.Arbor.Doctor.ProviderPickerTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Mix.Tasks.Arbor.Doctor.ProviderPicker

  @priority [
    {"openrouter", :openrouter, :openrouter},
    {"ollama", :ollama, :ollama_cloud},
    {"lm_studio", :lmstudio, :lmstudio},
    {"acp", :acp, :acp},
    {"opencode_zen", :opencode_zen, :opencode_zen},
    {"anthropic", :anthropic, :anthropic}
  ]

  defp entry(provider, display_name),
    do: %{provider: provider, display_name: display_name, available?: true, check_result: :ok}

  defp keyed(provider, display_name, var) do
    %{
      provider: provider,
      display_name: display_name,
      available?: false,
      check_result: {:error, [{:env_vars, {:missing, [%{name: var, required: true}], nil}}]}
    }
  end

  describe "options/2 with providers that only need an API key" do
    test "lists them after the ready ones, tagged with the env var, never recommended" do
      entries = [
        keyed("anthropic", "Anthropic", "ANTHROPIC_API_KEY"),
        entry("opencode_zen", "OpenCode Zen (free)"),
        keyed("openrouter", "OpenRouter", "OPENROUTER_API_KEY")
      ]

      options = ProviderPicker.options(entries, @priority)

      assert Enum.map(options, &{&1.catalog_key, &1.needs_key, &1.recommended?}) == [
               {"opencode_zen", nil, true},
               {"openrouter", "OPENROUTER_API_KEY", false},
               {"anthropic", "ANTHROPIC_API_KEY", false}
             ]

      assert ProviderPicker.render(options) =~ "3) Anthropic"
      assert ProviderPicker.render(options) =~ "(needs ANTHROPIC_API_KEY)"
    end

    test "a provider missing more than an env var is not offered" do
      probe_failed = %{
        provider: "ollama",
        display_name: "Ollama",
        available?: false,
        check_result: {:error, [{:probes, {:failed, ["http://localhost:11434"], nil}}]}
      }

      two_vars = %{
        keyed("anthropic", "Anthropic", "X")
        | check_result:
            {:error, [{:env_vars, {:missing, [%{name: "A", required: true}, %{name: "B"}], nil}}]}
      }

      assert ProviderPicker.options([probe_failed, two_vars], @priority) == []
    end

    test "a keyed-only menu has no recommended entry, but Enter still takes the first" do
      options =
        ProviderPicker.options([keyed("anthropic", "Anthropic", "ANTHROPIC_API_KEY")], @priority)

      assert [%{recommended?: false, needs_key: "ANTHROPIC_API_KEY"}] = options
      assert {:ok, %{catalog_key: "anthropic"}} = ProviderPicker.parse_selection("", options)
    end
  end

  describe "options/3 with installed ACP agents" do
    test "expands the ACP row into one row per agent, in the given order" do
      entries = [entry("acp", "ACP (CLI Agents)"), entry("opencode_zen", "OpenCode Zen (free)")]

      options = ProviderPicker.options(entries, @priority, acp_agents: ["claude", "codex"])

      assert Enum.map(options, &{&1.index, &1.catalog_key, &1.acp_agent, &1.display_name}) == [
               {1, "acp", "claude", "ACP: Claude Code"},
               {2, "acp", "codex", "ACP: Codex"},
               {3, "opencode_zen", nil, "OpenCode Zen (free)"}
             ]

      assert [%{recommended?: true}, %{recommended?: false}, %{recommended?: false}] = options
      assert ProviderPicker.render(options) =~ "2) ACP: Codex"
      assert ProviderPicker.render(options) =~ "acp/codex"
    end

    test "an agent id selects its row; `acp` alone selects the first agent" do
      entries = [entry("acp", "ACP (CLI Agents)")]
      options = ProviderPicker.options(entries, @priority, acp_agents: ["claude", "codex"])

      assert {:ok, %{acp_agent: "codex"}} = ProviderPicker.parse_selection("codex", options)
      assert {:ok, %{acp_agent: "codex"}} = ProviderPicker.parse_selection("Codex", options)
      assert {:ok, %{acp_agent: "claude"}} = ProviderPicker.parse_selection("acp", options)
      assert {:ok, %{acp_agent: "claude"}} = ProviderPicker.parse_selection("", options)
    end

    test "without agent information ACP stays a single row" do
      options = ProviderPicker.options([entry("acp", "ACP (CLI Agents)")], @priority)

      assert [%{catalog_key: "acp", acp_agent: nil, display_name: "ACP (CLI Agents)"}] = options
    end
  end

  describe "parse_api_key/1" do
    test "trims and accepts a single-line key" do
      assert {:ok, "sk-test-123"} = ProviderPicker.parse_api_key("  sk-test-123\n")
    end

    test "rejects empty and multi-line input" do
      assert {:error, :empty} = ProviderPicker.parse_api_key("   \n")
      assert {:error, :empty} = ProviderPicker.parse_api_key(nil)
      assert {:error, :multiline} = ProviderPicker.parse_api_key("a\nb")
    end
  end

  describe "options/2" do
    test "lists only ready providers, in priority order, recommending the first" do
      ready = [
        entry("anthropic", "Anthropic"),
        entry("opencode_zen", "OpenCode Zen (free)"),
        entry("lm_studio", "LM Studio")
      ]

      options = ProviderPicker.options(ready, @priority)

      assert Enum.map(options, & &1.catalog_key) == ["lm_studio", "opencode_zen", "anthropic"]
      assert Enum.map(options, & &1.index) == [1, 2, 3]
      assert Enum.map(options, & &1.recommended?) == [true, false, false]
      assert hd(options).config_atom == :lmstudio
      assert hd(options).llmdb_atom == :lmstudio
      assert hd(options).display_name == "LM Studio"
    end

    test "a ready provider the doctor cannot configure is not offered" do
      ready = [entry("zenmux", "Zenmux"), entry("anthropic", "Anthropic")]

      assert [%{catalog_key: "anthropic"}] = ProviderPicker.options(ready, @priority)
    end

    test "no ready providers gives an empty menu" do
      assert ProviderPicker.options([], @priority) == []
    end
  end

  describe "parse_selection/2" do
    setup do
      ready = [entry("opencode_zen", "OpenCode Zen (free)"), entry("anthropic", "Anthropic")]
      %{options: ProviderPicker.options(ready, @priority)}
    end

    test "empty input takes the recommended option", %{options: options} do
      assert {:ok, %{catalog_key: "opencode_zen", recommended?: true}} =
               ProviderPicker.parse_selection("", options)

      assert {:ok, %{catalog_key: "opencode_zen"}} = ProviderPicker.parse_selection("\n", options)
      assert {:ok, %{catalog_key: "opencode_zen"}} = ProviderPicker.parse_selection(nil, options)
    end

    test "a menu number selects that option", %{options: options} do
      assert {:ok, %{catalog_key: "anthropic"}} = ProviderPicker.parse_selection("2\n", options)

      assert {:ok, %{catalog_key: "opencode_zen"}} =
               ProviderPicker.parse_selection(" 1 ", options)
    end

    test "a provider name selects it, by catalog key or config atom, any case",
         %{options: options} do
      assert {:ok, %{catalog_key: "anthropic"}} =
               ProviderPicker.parse_selection("Anthropic", options)

      assert {:ok, %{catalog_key: "opencode_zen"}} =
               ProviderPicker.parse_selection("opencode_zen", options)

      ready = [entry("lm_studio", "LM Studio")]
      lm = ProviderPicker.options(ready, @priority)
      assert {:ok, %{catalog_key: "lm_studio"}} = ProviderPicker.parse_selection("lmstudio", lm)
    end

    test "out-of-range numbers and unknown names are rejected", %{options: options} do
      assert {:error, {:out_of_range, 9}} = ProviderPicker.parse_selection("9", options)
      assert {:error, {:out_of_range, 0}} = ProviderPicker.parse_selection("0", options)
      assert {:error, {:unknown, "groq"}} = ProviderPicker.parse_selection("groq", options)
    end

    test "an empty menu cannot be selected from" do
      assert {:error, :empty_menu} = ProviderPicker.parse_selection("1", [])
    end
  end

  describe "render/1" do
    test "numbers every option and marks the recommended one" do
      ready = [entry("opencode_zen", "OpenCode Zen (free)"), entry("anthropic", "Anthropic")]
      rendered = ProviderPicker.render(ProviderPicker.options(ready, @priority))

      assert rendered =~ "1) OpenCode Zen (free)  opencode_zen  (recommended)"
      assert rendered =~ "2) Anthropic"
      refute rendered =~ "2) Anthropic            anthropic  (recommended)"
    end
  end
end
