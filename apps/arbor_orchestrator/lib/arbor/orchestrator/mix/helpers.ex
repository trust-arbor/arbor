defmodule Arbor.Orchestrator.Mix.Helpers do
  @moduledoc false

  def info(msg), do: Mix.shell().info(msg)
  def success(msg), do: Mix.shell().info([:green, to_string(msg)])
  def warn(msg), do: Mix.shell().info([:yellow, to_string(msg)])
  def error(msg), do: Mix.shell().error([:red, to_string(msg)])
end
