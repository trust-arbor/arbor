defmodule Arbor.Historian.StreamIds do
  @moduledoc """
  Helper functions for building stream IDs.

  Streams are named using a prefix:id pattern for consistent querying.
  """

  @doc "Build a stream ID for an agent."
  @spec for_agent(String.t()) :: String.t()
  def for_agent(agent_id), do: "agent:#{agent_id}"

  @doc "Build a stream ID for a category."
  @spec for_category(atom()) :: String.t()
  def for_category(category), do: "category:#{category}"

  @doc "Build a stream ID for a session."
  @spec for_session(String.t()) :: String.t()
  def for_session(session_id), do: "session:#{session_id}"

  @doc "Build a stream ID for a correlation chain."
  @spec for_correlation(String.t()) :: String.t()
  def for_correlation(correlation_id), do: "correlation:#{correlation_id}"
end
