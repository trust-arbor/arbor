defmodule Arbor.Security.ProviderGate.Core do
  @moduledoc """
  Pure closed-root plan for Security OIDC/JWT/HTTP providers.

  No Process, IO, Application, or time is consulted.
  """

  @roots [:joken, :joken_jwks, :req]

  @doc "Closed provider roots started for :full with Security children."
  @spec roots() :: [atom()]
  def roots, do: @roots

  @doc "Plan roots for a closed start profile."
  @spec plan(term()) :: {:ok, [atom()]} | {:error, {:invalid_start_profile, term()}}
  def plan(:full), do: {:ok, @roots}
  def plan(:activation_only), do: {:ok, []}
  def plan(other), do: {:error, {:invalid_start_profile, other}}
end
