defmodule Arbor.Web do
  @moduledoc """
  Phoenix LiveView foundation kit for Arbor dashboards.

  Provides shared components, theme system, layout macros, JS hooks,
  and endpoint/router boilerplate that individual apps compose on top of.

  ## Usage

      # In a LiveView
      use Arbor.Web, :live_view

      # In a LiveComponent
      use Arbor.Web, :live_component

      # In a function component module
      use Arbor.Web, :component

      # In a router
      use Arbor.Web, :router

      # In an HTML helper module
      use Arbor.Web, :html
  """

  @doc """
  Invokes the appropriate `__using__` macro based on the given context.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  @doc false
  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(html_helpers())
    end
  end

  @doc false
  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  @doc false
  def component do
    quote do
      use Phoenix.Component
      unquote(html_helpers())
    end
  end

  @doc false
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc false
  def html do
    quote do
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      # Import Phoenix.Component for sigil_H and core functionality
      import Phoenix.Component, except: [flash: 1]

      import Arbor.Web.Components
      import Arbor.Web.Helpers
      import Arbor.Web.Icons

      # Routes and verified routes if available
      alias Phoenix.LiveView.JS
    end
  end
end
