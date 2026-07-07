defmodule Arbor.Trust.CapabilityProfileRegistry do
  @moduledoc """
  Resolved capability-profile coverage for registered non-action URI prefixes.

  `Arbor.Security.UriRegistry` owns URI membership. This module projects the
  trust-owned profile defaults over that registry and records an owner/reason
  row for registered prefixes that do not yet have a dedicated profile.

  Generated `arbor://action/...` prefixes are projected by `Arbor.Actions` so
  `arbor_trust` does not depend upward on `arbor_actions`. The provider is read
  through `Arbor.Trust.Config.action_profile_provider/0` at runtime.
  """

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Trust.{CapabilityRiskProfiles, Config}

  @type coverage_row :: %{
          required(:uri_prefix) => String.t(),
          required(:owner) => atom() | nil,
          required(:profile) => CapabilityProfile.t() | nil,
          required(:not_profileable_reason) => String.t() | nil
        }

  @doc "Return the resolved profiles known to the trust registry."
  @spec profiles() :: [CapabilityProfile.t()]
  def profiles do
    (CapabilityRiskProfiles.profiles() ++ action_namespace_profiles())
    |> Enum.uniq_by(& &1.uri_prefix)
    |> Enum.sort_by(& &1.uri_prefix)
  end

  @doc "Find the most-specific profile covering a resource URI or registered prefix."
  @spec profile_for(String.t()) :: CapabilityProfile.t() | nil
  def profile_for(uri) when is_binary(uri) do
    profiles()
    |> Enum.filter(&CapabilityUri.prefix_match?(&1.uri_prefix, uri))
    |> Enum.sort_by(
      fn profile -> profile.uri_prefix |> CapabilityUri.parse!() |> length_segments() end,
      :desc
    )
    |> List.first()
  end

  def profile_for(_uri), do: nil

  @doc """
  Return coverage rows for canonical security-owned registry prefixes.

  A row is complete when it has a profile, or when it has both an owner and an
  explicit `not_profileable_reason`.
  """
  @spec coverage_rows() :: [coverage_row()]
  def coverage_rows do
    Arbor.Security.canonical_uri_prefixes()
    |> Enum.map(&canonicalize_prefix!/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&coverage_row/1)
  end

  @doc "Rows missing both a profile and a complete owner/reason annotation."
  @spec coverage_gaps() :: [coverage_row()]
  def coverage_gaps do
    Enum.reject(coverage_rows(), &complete_row?/1)
  end

  @doc "True when every canonical registered prefix has a profile or reason row."
  @spec coverage_complete?() :: boolean()
  def coverage_complete?, do: coverage_gaps() == []

  @doc "Return the owner for a canonical registered prefix, when known."
  @spec owner_for(String.t()) :: atom() | nil
  def owner_for(uri_prefix) when is_binary(uri_prefix) do
    with {:ok, parsed} <- CapabilityUri.parse(uri_prefix) do
      owner_for_parsed(parsed)
    else
      _ -> nil
    end
  end

  def owner_for(_uri_prefix), do: nil

  defp coverage_row(uri_prefix) do
    profile = profile_for(uri_prefix)
    owner = if profile, do: profile.owner, else: owner_for(uri_prefix)

    %{
      uri_prefix: uri_prefix,
      owner: owner,
      profile: profile,
      not_profileable_reason: not_profileable_reason(uri_prefix, owner, profile)
    }
  end

  defp complete_row?(%{profile: %CapabilityProfile{}}), do: true

  defp complete_row?(%{owner: owner, not_profileable_reason: reason})
       when is_atom(owner) and is_binary(reason) do
    String.trim(reason) != ""
  end

  defp complete_row?(_row), do: false

  defp not_profileable_reason(_uri_prefix, _owner, %CapabilityProfile{}), do: nil

  defp not_profileable_reason(_uri_prefix, nil, nil), do: nil

  defp not_profileable_reason(_uri_prefix, owner, nil) do
    "owned by #{owner}; no dedicated risk profile is declared for this registered " <>
      "prefix yet, so it remains governed by facade authorization and explicit grants"
  end

  defp owner_for_parsed(%CapabilityUri{domain: "shell"}), do: :arbor_shell
  defp owner_for_parsed(%CapabilityUri{domain: "historian"}), do: :arbor_historian
  defp owner_for_parsed(%CapabilityUri{domain: "persistence"}), do: :arbor_persistence
  defp owner_for_parsed(%CapabilityUri{domain: "sandbox"}), do: :arbor_sandbox
  defp owner_for_parsed(%CapabilityUri{domain: "agent"}), do: :arbor_agent
  defp owner_for_parsed(%CapabilityUri{domain: "chat"}), do: :arbor_gateway
  defp owner_for_parsed(%CapabilityUri{domain: "memory"}), do: :arbor_memory
  defp owner_for_parsed(%CapabilityUri{domain: "consensus"}), do: :arbor_consensus
  defp owner_for_parsed(%CapabilityUri{domain: "comms"}), do: :arbor_comms
  defp owner_for_parsed(%CapabilityUri{domain: "signals"}), do: :arbor_signals
  defp owner_for_parsed(%CapabilityUri{domain: "mcp"}), do: :arbor_gateway
  defp owner_for_parsed(%CapabilityUri{domain: "tool"}), do: :arbor_gateway
  defp owner_for_parsed(%CapabilityUri{domain: "status"}), do: :arbor_gateway
  defp owner_for_parsed(%CapabilityUri{domain: "fs"}), do: :arbor_security
  defp owner_for_parsed(%CapabilityUri{domain: "code"}), do: :arbor_actions
  defp owner_for_parsed(%CapabilityUri{domain: "ai"}), do: :arbor_ai
  defp owner_for_parsed(%CapabilityUri{domain: "net"}), do: :arbor_actions
  defp owner_for_parsed(%CapabilityUri{domain: "eval"}), do: :arbor_actions
  defp owner_for_parsed(%CapabilityUri{domain: "monitor"}), do: :arbor_monitor
  defp owner_for_parsed(%CapabilityUri{domain: "trust"}), do: :arbor_trust
  defp owner_for_parsed(%CapabilityUri{domain: "governance"}), do: :arbor_trust
  defp owner_for_parsed(%CapabilityUri{domain: "acp"}), do: :arbor_gateway
  defp owner_for_parsed(%CapabilityUri{domain: "orchestrator"}), do: :arbor_orchestrator
  defp owner_for_parsed(%CapabilityUri{domain: "pipeline"}), do: :arbor_orchestrator
  defp owner_for_parsed(%CapabilityUri{domain: "handler"}), do: :arbor_orchestrator
  defp owner_for_parsed(_parsed), do: nil

  defp canonicalize_prefix!(uri_prefix) do
    uri_prefix
    |> CapabilityUri.parse!()
    |> CapabilityUri.canonical()
  end

  defp length_segments(%CapabilityUri{segments: segments}), do: length(segments)

  defp action_namespace_profiles do
    provider = Config.action_profile_provider()

    if is_atom(provider) &&
         Code.ensure_loaded?(provider) &&
         function_exported?(provider, :action_namespace_capability_profiles, 0) do
      provider
      |> apply(:action_namespace_capability_profiles, [])
      |> Enum.filter(&match?(%CapabilityProfile{}, &1))
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
