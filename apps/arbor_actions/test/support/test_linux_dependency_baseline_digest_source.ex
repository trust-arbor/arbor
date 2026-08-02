defmodule Arbor.Actions.TestLinuxDependencyBaselineDigestSource do
  @moduledoc false

  # Test-only stand-in for `Arbor.Shell.linux_dependency_baseline_mix_lock_digest/0`.
  # Wired exclusively through `Arbor.Actions.Config.dependency_baseline_digest_module/0`
  # (an Application-env getter) — never via action params or context, so the
  # digest source cannot be shaped by anything flowing through the Engine/DOT
  # graph.

  use Agent

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> :unavailable end, name: name)
  end

  @doc false
  def reset do
    ensure_agent()
    Agent.update(__MODULE__, fn _ -> :unavailable end)
  end

  @doc "Configure the next checkout to return `{:ok, digest}`."
  def set_digest(digest) when is_binary(digest) do
    ensure_agent()
    Agent.update(__MODULE__, fn _ -> {:digest, digest} end)
  end

  @doc "Configure the next checkout to return the real facade's own unavailable-state error."
  def set_unavailable do
    ensure_agent()
    Agent.update(__MODULE__, fn _ -> :unavailable end)
  end

  @doc false
  def linux_dependency_baseline_mix_lock_digest do
    ensure_agent()

    case Agent.get(__MODULE__, & &1) do
      {:digest, digest} -> {:ok, digest}
      :unavailable -> {:error, :linux_dependency_baseline_unavailable}
    end
  end

  defp ensure_agent do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
