defmodule Arbor.Common.TemplateRendererTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.TemplateRenderer

  describe "render/2" do
    test "replaces string-keyed bindings" do
      assert TemplateRenderer.render("Hello {{name}}", %{"name" => "world"}) ==
               "Hello world"
    end

    test "replaces atom-keyed bindings" do
      assert TemplateRenderer.render("Hello {{name}}", %{name: "world"}) ==
               "Hello world"
    end

    test "leaves unresolved vars unchanged" do
      assert TemplateRenderer.render("{{missing}} stays", %{}) ==
               "{{missing}} stays"
    end

    test "handles multiple vars" do
      template = "{{greeting}} {{name}}, you have {{count}} items"
      bindings = %{"greeting" => "Hi", "name" => "Alice", "count" => "3"}

      assert TemplateRenderer.render(template, bindings) ==
               "Hi Alice, you have 3 items"
    end

    test "converts non-string values to string" do
      assert TemplateRenderer.render("Count: {{n}}", %{"n" => 42}) == "Count: 42"
    end

    test "handles empty template" do
      assert TemplateRenderer.render("", %{"key" => "val"}) == ""
    end

    test "handles template with no vars" do
      assert TemplateRenderer.render("plain text", %{"key" => "val"}) == "plain text"
    end

    test "handles repeated var" do
      assert TemplateRenderer.render("{{x}} and {{x}}", %{"x" => "y"}) == "y and y"
    end
  end

  describe "extract_vars/1" do
    test "extracts variable names" do
      vars = TemplateRenderer.extract_vars("Hello {{name}}, {{count}} items")
      assert "name" in vars
      assert "count" in vars
      assert length(vars) == 2
    end

    test "deduplicates repeated vars" do
      vars = TemplateRenderer.extract_vars("{{x}} and {{x}}")
      assert vars == ["x"]
    end

    test "returns empty list for no vars" do
      assert TemplateRenderer.extract_vars("plain text") == []
    end

    test "returns empty list for empty string" do
      assert TemplateRenderer.extract_vars("") == []
    end
  end
end
