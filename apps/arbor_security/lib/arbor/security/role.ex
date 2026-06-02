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

  - `:admin` — full access to all resources (`arbor://**`)
  - `:viewer` — least-privilege default for OIDC-authenticated humans;
    only ambient signal subscription
  - `:dev_admin` — only available when
    `config :arbor_security, :enable_dev_admin_role, true`. Bundles the
    capabilities that were previously auto-granted in dev (consensus admin
    + trust auto-promote wildcard + security signals) into one role so the
    dev bootstrap is a single `assign_role(human_id, :dev_admin)` call.
    Never exposed in production unless explicitly enabled.
  """

  alias Arbor.Security.Config

  require Logger

  # M1: :viewer is the least-privilege built-in role used as the OIDC login
  # default. Holds only ambient signal subscription — no write, no admin,
  # no agent control. Operators that need a richer baseline should define
  # custom roles via `config :arbor_security, :roles, %{...}`.
  @builtin_roles %{
    admin: [
      "arbor://**"
    ],
    viewer: [
      "arbor://signals/subscribe/security"
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

    @builtin_roles
    |> Map.merge(dev_admin_role())
    |> Map.merge(configured)
  end

  # OQ-2: :dev_admin is only registered when the operator explicitly opts in.
  # Production must not see this role even by accident.
  defp dev_admin_role do
    if Application.get_env(:arbor_security, :enable_dev_admin_role, false) do
      %{
        dev_admin: [
          "arbor://consensus/admin",
          "arbor://trust/auto_promote/**",
          "arbor://signals/subscribe/security"
        ]
      }
    else
      %{}
    end
  end
end
