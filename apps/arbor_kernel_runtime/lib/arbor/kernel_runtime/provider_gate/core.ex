defmodule Arbor.KernelRuntime.ProviderGate.Core do
  @moduledoc """
  Pure closed-root plan for Kernel Runtime providers.

  No Process, IO, Application, or time is consulted.
  """

  @roots [:os_mon, :recon, :mint, :finch, :req]

  @doc "Closed provider roots started for :full with nested consumers."
  @spec roots() :: [atom()]
  def roots, do: @roots

  @doc "Plan roots for a closed start profile."
  @spec plan(term()) :: {:ok, [atom()]} | {:error, {:invalid_start_profile, term()}}
  def plan(:full), do: {:ok, @roots}
  def plan(:activation_only), do: {:ok, []}
  def plan(other), do: {:error, {:invalid_start_profile, other}}
end
