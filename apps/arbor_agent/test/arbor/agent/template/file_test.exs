defmodule Arbor.Agent.Template.FileTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Template.File, as: TemplateFile
  alias Arbor.Agent.TemplateStore

  # The 10 builtin template modules (from TemplateStore.@builtin_modules). This
  # is the fidelity guarantee for the data-first migration: serialize -> parse
  # must round-trip every builtin exactly (ignoring only the volatile
  # created_at/updated_at timestamps), and validate/1 must pass.
  @builtin_modules [
    Arbor.Agent.Templates.CliAgent,
    Arbor.Agent.Templates.Scout,
    Arbor.Agent.Templates.Researcher,
    Arbor.Agent.Templates.CodeReviewer,
    Arbor.Agent.Templates.Monitor,
    Arbor.Agent.Templates.Diagnostician,
    Arbor.Agent.Templates.Conversationalist,
    Arbor.Agent.Templates.InterviewAgent,
    Arbor.Agent.Templates.ApiAgent,
    Arbor.Agent.Templates.CouncilEvaluator
  ]

  @volatile ~w(created_at updated_at)

  describe "serialize/1 + parse/1 round-trip" do
    for module <- @builtin_modules do
      test "round-trips #{inspect(module)} losslessly" do
        module = unquote(module)
        data = TemplateStore.from_module(module)

        markdown = TemplateFile.serialize(data)
        assert {:ok, parsed} = TemplateFile.parse(markdown)

        assert Map.drop(parsed, @volatile) == Map.drop(data, @volatile),
               "round-trip mismatch for #{inspect(module)}"
      end
    end
  end

  describe "validate/1" do
    for module <- @builtin_modules do
      test "validates #{inspect(module)}" do
        module = unquote(module)
        data = TemplateStore.from_module(module)
        assert :ok = TemplateFile.validate(data)

        # also valid after a round-trip
        {:ok, parsed} = TemplateFile.parse(TemplateFile.serialize(data))
        assert :ok = TemplateFile.validate(parsed)
      end
    end

    test "rejects a missing character name" do
      data = %{
        "character" => %{},
        "trust_tier" => "probationary",
        "initial_goals" => [],
        "required_capabilities" => []
      }

      assert {:error, reasons} = TemplateFile.validate(data)
      assert {:character, :missing_name} in reasons
    end

    test "rejects an unknown trust tier" do
      data = %{
        "character" => %{"name" => "X"},
        "trust_tier" => "godmode",
        "initial_goals" => [],
        "required_capabilities" => []
      }

      assert {:error, reasons} = TemplateFile.validate(data)
      assert Enum.any?(reasons, &match?({:trust_tier, _}, &1))
    end

    test "rejects malformed goals and capabilities" do
      data = %{
        "character" => %{"name" => "X"},
        "trust_tier" => "trusted",
        "initial_goals" => [%{"type" => "achieve"}],
        "required_capabilities" => [%{"description" => "no resource"}]
      }

      assert {:error, reasons} = TemplateFile.validate(data)
      assert Enum.any?(reasons, &match?({:initial_goals, _}, &1))
      assert Enum.any?(reasons, &match?({:required_capabilities, _}, &1))
    end
  end
end
