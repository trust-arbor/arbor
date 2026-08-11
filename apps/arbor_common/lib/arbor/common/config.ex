defmodule Arbor.Common.Config do
  @moduledoc """
  Application env for `arbor_common`.

  Skill hybrid-search seams default to `nil` (disabled). Umbrella runtime or
  tests inject concrete modules; this library never hardcodes persistence or
  embedding providers.
  """

  @doc "Module implementing `Arbor.Contracts.API.Embedding`, or `nil`."
  @spec skill_embedding_module() :: module() | nil
  def skill_embedding_module do
    Application.get_env(:arbor_common, :skill_embedding_module, nil)
  end

  @doc """
  Module exposing skill persistence facade callbacks, or `nil`.

  Expected callbacks when configured:
  `skill_search_capability/0`, `hybrid_search_skills/3`,
  `hybrid_search_skills_with_meta/3`, `upsert_skills/1`, `upsert_skill/1`,
  `get_skill_record/1`.
  """
  @spec skill_persistence_module() :: module() | nil
  def skill_persistence_module do
    Application.get_env(:arbor_common, :skill_persistence_module, nil)
  end

  @doc "Expected embedding dimensionality (default 768). Always a positive integer."
  @spec skill_embedding_dimensions() :: pos_integer()
  def skill_embedding_dimensions do
    case Application.get_env(:arbor_common, :skill_embedding_dimensions, 768) do
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
    case Application.get_env(:arbor_common, :skill_sync_max_attempts, 30) do
      n when is_integer(n) and n >= 1 -> n
      _ -> 30
    end
  end

  defp positive_ms(key, default) do
    case Application.get_env(:arbor_common, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp non_negative_ms(key, default) do
    case Application.get_env(:arbor_common, key, default) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end
end
