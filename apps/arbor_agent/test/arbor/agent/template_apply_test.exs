defmodule Arbor.Agent.TemplateApplyTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Template
  alias Arbor.Agent.Templates.ClaudeCode
  alias Arbor.Agent.Templates.Scout

  describe "Template.apply/1" do
    test "extracts all callbacks from ClaudeCode template" do
      config = Template.apply(ClaudeCode)

      assert config[:name] == "Claude"
      assert config[:character].name == "Claude"
      assert config[:trust_tier] == :established
      assert length(config[:initial_goals]) == 3
      assert length(config[:required_capabilities]) >= 5

      # Optional callbacks present on ClaudeCode
      assert is_binary(config[:nature])
      assert String.length(config[:nature]) > 0
      assert is_list(config[:values])
      assert length(config[:values]) >= 4
      assert is_list(config[:interests])
      assert length(config[:interests]) >= 3
      assert [_ | _] = config[:initial_thoughts]
      assert is_map(config[:relationship_style])
      assert Map.has_key?(config[:relationship_style], :approach)
      assert is_binary(config[:domain_context])
      assert String.length(config[:domain_context]) > 0
    end

    test "extracts all callbacks from Scout template" do
      config = Template.apply(Scout)

      assert config[:name] == "Scout"
      assert config[:character].name == "Scout"
      assert config[:trust_tier] == :probationary

      # Optional callbacks now present on Scout
      assert is_binary(config[:nature])
      assert String.contains?(config[:nature], "reconnaissance")
      assert is_list(config[:values])
      assert length(config[:values]) >= 3
      assert is_list(config[:interests])
      assert length(config[:interests]) >= 2
      assert [_ | _] = config[:initial_thoughts]
      assert is_map(config[:relationship_style])
      assert Map.has_key?(config[:relationship_style], :approach)
      assert is_binary(config[:domain_context])
      assert String.length(config[:domain_context]) > 0
    end

    test "includes meta-awareness about template origin" do
      config = Template.apply(ClaudeCode)

      assert config[:meta_awareness][:grown_from_template] == true
      assert config[:meta_awareness][:template_name] == "Claude"
      assert config[:meta_awareness][:note] =~ "template"
    end
  end
end
