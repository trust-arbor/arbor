defmodule Arbor.Web.Theme do
  @moduledoc """
  Color palette and CSS class builders for Arbor dashboards.

  All CSS classes use the `aw-` prefix to avoid conflicts with app-specific styles.
  Colors are defined as CSS custom properties (--aw-*) in arbor_web.css.
  """

  @type color_name ::
          :green | :yellow | :red | :blue | :purple | :orange | :gray

  @type status_name ::
          :ok | :success | :running | :healthy
          | :warning | :pending | :degraded
          | :error | :failed | :critical | :offline
          | :info | :active | :unknown

  @default_colors %{
    green: "#3fb950",
    yellow: "#d29922",
    red: "#f85149",
    blue: "#58a6ff",
    purple: "#bc8cff",
    orange: "#f0883e",
    gray: "#8b949e"
  }

  @status_color_map %{
    # Green statuses
    ok: :green,
    success: :green,
    running: :green,
    healthy: :green,
    # Yellow statuses
    warning: :yellow,
    pending: :yellow,
    degraded: :yellow,
    # Red statuses
    error: :red,
    failed: :red,
    critical: :red,
    offline: :red,
    # Blue statuses
    info: :blue,
    active: :blue,
    # Default
    unknown: :gray
  }

  @doc """
  Returns the color palette map.

  Reads from application env `:arbor_web, :theme_colors` with defaults.
  Override in config to customize:

      config :arbor_web, theme_colors: %{blue: "#00d4ff", green: "#00ff88"}

  Partial overrides are merged with defaults.
  """
  @spec colors() :: %{color_name() => String.t()}
  def colors do
    custom = Application.get_env(:arbor_web, :theme_colors, %{})
    Map.merge(@default_colors, custom)
  end

  @doc """
  Returns the hex color value for a named color.

  Respects custom theme colors configured via application env.
  """
  @spec color(atom()) :: String.t()
  def color(name) when is_atom(name) do
    palette = colors()
    Map.get(palette, name, palette[:gray])
  end

  @doc """
  Returns the CSS background class for a status or color name.

  ## Examples

      iex> Arbor.Web.Theme.bg_class(:success)
      "aw-bg-green"

      iex> Arbor.Web.Theme.bg_class(:blue)
      "aw-bg-blue"
  """
  @spec bg_class(atom()) :: String.t()
  def bg_class(status_or_color) do
    "aw-bg-#{resolve_color_name(status_or_color)}"
  end

  @doc """
  Returns the CSS text color class for a status or color name.

  ## Examples

      iex> Arbor.Web.Theme.text_class(:error)
      "aw-text-red"

      iex> Arbor.Web.Theme.text_class(:purple)
      "aw-text-purple"
  """
  @spec text_class(atom()) :: String.t()
  def text_class(status_or_color) do
    "aw-text-#{resolve_color_name(status_or_color)}"
  end

  @doc """
  Returns the CSS border color class for a status or color name.

  ## Examples

      iex> Arbor.Web.Theme.border_class(:warning)
      "aw-border-yellow"

      iex> Arbor.Web.Theme.border_class(:green)
      "aw-border-green"
  """
  @spec border_class(atom()) :: String.t()
  def border_class(status_or_color) do
    "aw-border-#{resolve_color_name(status_or_color)}"
  end

  @doc """
  Resolves a status or color atom to its color name.

  ## Examples

      iex> Arbor.Web.Theme.resolve_color_name(:success)
      :green

      iex> Arbor.Web.Theme.resolve_color_name(:blue)
      :blue
  """
  @spec resolve_color_name(atom()) :: color_name()
  def resolve_color_name(status_or_color) when is_atom(status_or_color) do
    cond do
      Map.has_key?(@status_color_map, status_or_color) ->
        Map.fetch!(@status_color_map, status_or_color)

      Map.has_key?(@default_colors, status_or_color) ->
        status_or_color

      true ->
        :gray
    end
  end
end
