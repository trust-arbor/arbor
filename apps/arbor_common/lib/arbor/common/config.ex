defmodule Arbor.Common.Config do
  @moduledoc """
  Owner-scoped application env for Common.

  Values live under `config :arbor_kernel, common: [...]` and are read through
  `Arbor.Kernel.ConfigCompat` during the compatibility window. Skill
  hybrid-search, telemetry persistence, action URI, and skill-import security
  seams default to `nil` (disabled). Umbrella runtime or tests inject concrete
  modules; this library never hardcodes those providers.
  """

  @doc "Module implementing `Arbor.Contracts.API.Embedding`, or `nil`."
  @spec skill_embedding_module() :: module() | nil
  def skill_embedding_module, do: get(:skill_embedding_module, nil)

  @doc """
  Module exposing skill persistence facade callbacks, or `nil`.

  Expected callbacks when configured:
  `skill_search_capability/0`, `hybrid_search_skills/3`,
  `hybrid_search_skills_with_meta/3`, `upsert_skills/1`, `upsert_skill/1`,
  `get_skill_record/1`.
  """
  @spec skill_persistence_module() :: module() | nil
  def skill_persistence_module, do: get(:skill_persistence_module, nil)

  @doc """
  Module implementing `Arbor.Common.AgentTelemetry.Persistence`, or `nil`.

  Expected callbacks when configured: `persist_event/3`, `load_lifetime/1`,
  `query_events/2`.
  """
  @spec telemetry_persistence_module() :: module() | nil
  def telemetry_persistence_module, do: get(:telemetry_persistence_module, nil)

  @doc """
  Module implementing `Arbor.Common.CapabilityProviders.ActionCapabilityURI`, or `nil`.
  """
  @spec action_capability_uri_module() :: module() | nil
  def action_capability_uri_module, do: get(:action_capability_uri_module, nil)

  @doc """
  Module implementing `Arbor.Common.SkillImporter.Security`, or `nil`.
  """
  @spec skill_import_security_module() :: module() | nil
  def skill_import_security_module, do: get(:skill_import_security_module, nil)

  @doc "Expected embedding dimensionality (default 768). Always a positive integer."
  @spec skill_embedding_dimensions() :: pos_integer()
  def skill_embedding_dimensions do
    case get(:skill_embedding_dimensions, 768) do
      n when is_integer(n) and n > 0 -> n
      _ -> 768
    end
  end

  @doc "Initial delay before first startup skill-store sync attempt (ms)."
  @spec skill_sync_initial_delay_ms() :: non_neg_integer()
  def skill_sync_initial_delay_ms do
    non_negative_ms(:skill_sync_initial_delay_ms, 1_000)
  end

  @doc "Delay between startup skill-store sync retries while persistence is unavailable (ms)."
  @spec skill_sync_retry_delay_ms() :: pos_integer()
  def skill_sync_retry_delay_ms do
    positive_ms(:skill_sync_retry_delay_ms, 500)
  end

  @doc "Max startup skill-store sync attempts (including the first)."
  @spec skill_sync_max_attempts() :: pos_integer()
  def skill_sync_max_attempts do
    case get(:skill_sync_max_attempts, 30) do
      n when is_integer(n) and n >= 1 -> n
      _ -> 30
    end
  end

  @doc "Whether Common starts its optional supervised children (default true)."
  @spec start_children?() :: term()
  def start_children?, do: get(:start_children, true)

  @doc "Configured skill search directories, or `nil` when unset."
  @spec skill_dirs() :: term()
  def skill_dirs, do: get(:skill_dirs, nil)

  @doc "Trust-zone map, or `:disabled` (default)."
  @spec trust_zones() :: term()
  def trust_zones, do: get(:trust_zones, :disabled)

  @doc "OAuth HTTP adapter module (default `Arbor.Common.OAuth.HttpClient.Req`)."
  @spec oauth_http_client() :: term()
  def oauth_http_client, do: get(:oauth_http_client, Arbor.Common.OAuth.HttpClient.Req)

  @doc "Whether project-context auto-load is enabled (default false)."
  @spec project_context_enabled?() :: term()
  def project_context_enabled?, do: get(:project_context_enabled, false)

  @doc "Whether the skill catalog is enabled (default false)."
  @spec skill_catalog_enabled?() :: term()
  def skill_catalog_enabled?, do: get(:skill_catalog_enabled, false)

  @doc "Whether the tool catalog is enabled (default false)."
  @spec tool_catalog_enabled?() :: term()
  def tool_catalog_enabled?, do: get(:tool_catalog_enabled, false)

  @doc "Capability-resolver keyword options (default `[]`)."
  @spec capability_resolver() :: term()
  def capability_resolver, do: get(:capability_resolver, [])

  @doc "Hands Mix-task keyword options (default `[]`)."
  @spec hands() :: term()
  def hands, do: get(:hands, [])

  defp get(key, default) do
    Arbor.Kernel.ConfigCompat.get_env(:arbor_common, key, default)
  end

  defp positive_ms(key, default) do
    case get(key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp non_negative_ms(key, default) do
    case get(key, default) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end
end
