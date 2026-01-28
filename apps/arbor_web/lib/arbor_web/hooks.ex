defmodule Arbor.Web.Hooks do
  @moduledoc """
  Registry of JavaScript LiveView hook names provided by Arbor.Web.

  The actual JavaScript implementations live in `priv/static/arbor_web.js`.
  This module provides constants and documentation for each hook.

  ## Usage in LiveView templates

      <div id="timeline" phx-hook="EventTimeline">...</div>
      <form phx-hook="ClearOnSubmit">...</form>

  ## Usage in app.js

      import { ArborWebHooks } from "/assets/arbor_web.js";

      let liveSocket = new LiveSocket("/live", Socket, {
        hooks: { ...ArborWebHooks, ...MyAppHooks }
      });
  """

  @hooks %{
    scroll_to_bottom: "ScrollToBottom",
    clear_on_submit: "ClearOnSubmit",
    event_timeline: "EventTimeline",
    resizable_panel: "ResizablePanel",
    node_hexagon: "NodeHexagon"
  }

  @doc """
  Returns the JS hook name for a given hook key.

  ## Examples

      iex> Arbor.Web.Hooks.hook_name(:scroll_to_bottom)
      "ScrollToBottom"

      iex> Arbor.Web.Hooks.hook_name(:clear_on_submit)
      "ClearOnSubmit"
  """
  @spec hook_name(atom()) :: String.t()
  def hook_name(key) when is_atom(key) do
    Map.fetch!(@hooks, key)
  end

  @doc """
  Returns all registered hook names as a map.

  ## Examples

      iex> hooks = Arbor.Web.Hooks.all()
      iex> Map.has_key?(hooks, :scroll_to_bottom)
      true
  """
  @spec all() :: %{atom() => String.t()}
  def all, do: @hooks

  @doc """
  Returns just the JS hook name strings (for documentation/verification).

  ## Examples

      iex> "ScrollToBottom" in Arbor.Web.Hooks.names()
      true
  """
  @spec names() :: [String.t()]
  def names, do: Map.values(@hooks)
end
