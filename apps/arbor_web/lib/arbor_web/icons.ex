defmodule Arbor.Web.Icons do
  @moduledoc """
  Emoji/text icon mappings for consistent visual language across Arbor dashboards.
  """

  @event_icons %{
    # Activity types
    thinking: "🧠",
    speaking: "💬",
    acting: "⚡",
    observing: "👁",
    learning: "📚",
    deciding: "🎯",
    error: "❌",
    warning: "⚠️",
    success: "✅",
    info: "ℹ️",
    # System events
    started: "🚀",
    stopped: "🛑",
    connected: "🔗",
    disconnected: "🔌",
    heartbeat: "💓",
    checkpoint: "📍",
    migration: "🔄",
    # Agent lifecycle
    spawned: "🌱",
    terminated: "💀",
    suspended: "⏸",
    resumed: "▶️",
    # Communication
    message_sent: "📤",
    message_received: "📥",
    broadcast: "📡",
    handoff: "🤝",
    # Demo events
    fault_injected: "💥",
    fault_cleared: "🩹",
    anomaly_detected: "🚨"
  }

  @category_icons %{
    consensus: "🗳",
    security: "🔒",
    persistence: "💾",
    agent: "🤖",
    signal: "📡",
    shell: "🐚",
    web: "🌐",
    task: "📋",
    system: "⚙️",
    network: "🔗",
    debug: "🐛",
    demo: "🔬",
    monitor: "📊"
  }

  @perspective_icons %{
    security: "🛡",
    performance: "⚡",
    reliability: "🏗",
    maintainability: "🔧",
    usability: "👤",
    cost: "💰",
    risk: "⚠️",
    innovation: "💡",
    adversarial: "🗡"
  }

  @status_icons %{
    ok: "✅",
    success: "✅",
    running: "🟢",
    healthy: "💚",
    warning: "🟡",
    pending: "⏳",
    degraded: "🟠",
    error: "🔴",
    failed: "❌",
    critical: "🚨",
    offline: "⚫",
    unknown: "❓",
    active: "🔵"
  }

  @doc """
  Returns the icon for an event type.

  ## Examples

      iex> Arbor.Web.Icons.event_icon(:thinking)
      "🧠"

      iex> Arbor.Web.Icons.event_icon(:unknown_type)
      "•"
  """
  @spec event_icon(atom()) :: String.t()
  def event_icon(type) when is_atom(type) do
    Map.get(@event_icons, type, "•")
  end

  @doc """
  Returns the icon for a category.

  ## Examples

      iex> Arbor.Web.Icons.category_icon(:consensus)
      "🗳"

      iex> Arbor.Web.Icons.category_icon(:unknown)
      "📦"
  """
  @spec category_icon(atom()) :: String.t()
  def category_icon(category) when is_atom(category) do
    Map.get(@category_icons, category, "📦")
  end

  @doc """
  Returns the icon for a consensus perspective.

  ## Examples

      iex> Arbor.Web.Icons.perspective_icon(:security)
      "🛡"

      iex> Arbor.Web.Icons.perspective_icon(:unknown)
      "🔍"
  """
  @spec perspective_icon(atom()) :: String.t()
  def perspective_icon(perspective) when is_atom(perspective) do
    Map.get(@perspective_icons, perspective, "🔍")
  end

  @doc """
  Returns the icon for a status.

  ## Examples

      iex> Arbor.Web.Icons.status_icon(:running)
      "🟢"

      iex> Arbor.Web.Icons.status_icon(:unknown_status)
      "❓"
  """
  @spec status_icon(atom()) :: String.t()
  def status_icon(status) when is_atom(status) do
    Map.get(@status_icons, status, "❓")
  end

  @doc """
  Returns all event icon mappings.
  """
  @spec event_icons() :: %{atom() => String.t()}
  def event_icons, do: @event_icons

  @doc """
  Returns all category icon mappings.
  """
  @spec category_icons() :: %{atom() => String.t()}
  def category_icons, do: @category_icons

  @doc """
  Returns all perspective icon mappings.
  """
  @spec perspective_icons() :: %{atom() => String.t()}
  def perspective_icons, do: @perspective_icons

  @doc """
  Returns all status icon mappings.
  """
  @spec status_icons() :: %{atom() => String.t()}
  def status_icons, do: @status_icons
end
