defmodule Arbor.Common.TemplateRenderer do
  @moduledoc """
  Pure-function template variable substitution for skill bodies.

  Replaces `{{var}}` placeholders with values from a bindings map.
  Unresolved variables pass through unchanged. Nil values become empty strings.
  """

  @var_pattern ~r/\{\{(\w+)\}\}/

  @doc """
  Render a template by replacing `{{var}}` placeholders with values from bindings.

  ## Examples

      iex> Arbor.Common.TemplateRenderer.render("Hello {{name}}", %{"name" => "world"})
      "Hello world"

      iex> Arbor.Common.TemplateRenderer.render("{{missing}} stays", %{})
      "{{missing}} stays"

  """
  @spec render(String.t(), map()) :: String.t()
  def render(template, bindings) when is_binary(template) and is_map(bindings) do
    Regex.replace(@var_pattern, template, fn full_match, var_name ->
      resolve_var(bindings, var_name, full_match)
    end)
  end

  def render(template, _bindings) when is_binary(template), do: template

  defp resolve_var(bindings, var_name, fallback) do
    case Map.get(bindings, var_name) do
      nil -> resolve_atom_key(bindings, var_name, fallback)
      value -> to_string(value)
    end
  end

  defp resolve_atom_key(bindings, var_name, fallback) do
    atom_key = String.to_existing_atom(var_name)

    case Map.get(bindings, atom_key) do
      nil -> fallback
      value -> to_string(value)
    end
  rescue
    ArgumentError -> fallback
  end

  @doc """
  Extract all `{{var}}` placeholder names from a template.

  ## Examples

      iex> Arbor.Common.TemplateRenderer.extract_vars("Hello {{name}}, you have {{count}} items")
      ["name", "count"]

  """
  @spec extract_vars(String.t()) :: [String.t()]
  def extract_vars(template) when is_binary(template) do
    @var_pattern
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
