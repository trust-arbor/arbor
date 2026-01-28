defmodule Arbor.Web.TestHelpers do
  @moduledoc """
  LiveView testing utilities for Arbor dashboards.

  Provides helpers for rendering and asserting on Arbor.Web components
  in test environments.

  ## Usage

  In your test file:

      import Arbor.Web.TestHelpers

      test "renders stat card" do
        html = render_component(&Arbor.Web.Components.stat_card/1, %{
          value: "42",
          label: "Count"
        })

        assert_html(html, "aw-stat-card")
        assert_html(html, "42")
      end
  """

  import ExUnit.Assertions

  @doc """
  Renders a function component to an HTML string.

  Calls the component function with the given assigns and converts
  the rendered output to a string.

  ## Examples

      html = render_component(&Arbor.Web.Components.badge/1, %{label: "OK", color: :green})
      assert html =~ "aw-badge"
  """
  @spec render_component(function(), map()) :: String.t()
  def render_component(component, assigns \\ %{}) do
    assigns
    |> Map.put_new(:__changed__, %{})
    |> component.()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  @doc """
  Asserts that an HTML string contains the given text or pattern.

  ## Examples

      assert_html(html, "aw-stat-card")
      assert_html(html, ~r/class="aw-badge/)
  """
  @spec assert_html(String.t(), String.t() | Regex.t()) :: true
  def assert_html(html, pattern) when is_binary(pattern) do
    assert html =~ pattern,
           "Expected HTML to contain #{inspect(pattern)}, but got:\n#{html}"
  end

  def assert_html(html, %Regex{} = pattern) do
    assert html =~ pattern,
           "Expected HTML to match #{inspect(pattern)}, but got:\n#{html}"
  end

  @doc """
  Refutes that an HTML string contains the given text or pattern.

  ## Examples

      refute_html(html, "aw-hidden")
  """
  @spec refute_html(String.t(), String.t() | Regex.t()) :: false
  def refute_html(html, pattern) when is_binary(pattern) do
    refute html =~ pattern,
           "Expected HTML to NOT contain #{inspect(pattern)}, but it did:\n#{html}"
  end

  def refute_html(html, %Regex{} = pattern) do
    refute html =~ pattern,
           "Expected HTML to NOT match #{inspect(pattern)}, but it did:\n#{html}"
  end

  @doc """
  Counts occurrences of a pattern in an HTML string.

  ## Examples

      assert count_html(html, "aw-badge") == 3
  """
  @spec count_html(String.t(), String.t()) :: non_neg_integer()
  def count_html(html, pattern) when is_binary(html) and is_binary(pattern) do
    html
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
