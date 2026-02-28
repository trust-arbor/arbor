defmodule Arbor.Security.Role do
  @moduledoc """
  Named capability sets for assigned access control.

  Roles define static bundles of capabilities that can be assigned to
  identities (humans or agents). Unlike trust tiers, which are earned
  through behavioral progression, roles are explicitly assigned.

  ## Configuration

      config :arbor_security, :roles, %{
        admin: ["arbor://**"],
        developer: ["arbor://fs/**", "arbor://shell/execute/**", ...]
      }

  ## Built-in Roles

  - `:admin` — full access to all resources (default for OIDC-authenticated humans)
  """

  alias Arbor.Security.Config

  require Logger

  @builtin_roles %{
    admin: [
      "arbor://**"
    ]
  }

  @doc """
  Get the capability URIs for a role.

  Returns `{:ok, [uri]}` or `{:error, :unknown_role}`.
  """
  @spec get(atom()) :: {:ok, [String.t()]} | {:error, :unknown_role}
  def get(role_name) when is_atom(role_name) do
    case Map.get(all_roles(), role_name) do
      nil -> {:error, :unknown_role}
      uris -> {:ok, uris}
    end
  end

  @doc """
  List all defined role names.
  """
  @spec list() :: [atom()]
  def list do
    all_roles() |> Map.keys()
  end

  @doc """
  Get the default role for human identities.
  """
  @spec default_human_role() :: atom()
  def default_human_role do
    Config.default_human_role()
  end

  # Merge built-in roles with user-configured roles.
  # User config overrides built-in definitions for the same name.
  defp all_roles do
    configured = Application.get_env(:arbor_security, :roles, %{})
    Map.merge(@builtin_roles, configured)
  end
end
