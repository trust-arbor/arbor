defmodule Arbor.Contracts.SkillLibrary do
  @moduledoc """
  Behaviour for pluggable skill library backends.

  A skill library stores, indexes, and retrieves agent skills — reusable
  capabilities that agents can discover and invoke. The behaviour is designed
  to support multiple implementation tiers:

  - **arbor_common** provides a file-based implementation that scans directories
    for skill definitions and indexes them in ETS for fast lookup.

  - **arbor_persistence** can enhance this with Postgres-backed storage and
    pgvector semantic search for natural-language skill discovery.

  ## Implementing a SkillLibrary

  Minimal (file-based):

      defmodule MyFileSkillLibrary do
        @behaviour Arbor.Contracts.SkillLibrary

        @impl true
        def get(name), do: ...

        @impl true
        def list(opts), do: ...

        @impl true
        def search(query, opts), do: ...

        @impl true
        def register(skill), do: ...

        @impl true
        def index(dir, opts), do: ...
      end

  With semantic search (pgvector-backed):

      defmodule MySemanticSkillLibrary do
        @behaviour Arbor.Contracts.SkillLibrary

        # ... required callbacks ...
        # search/2 can use pgvector similarity search
        # for natural-language skill discovery
      end

  ## Usage

  Configure the skill library backend per application:

      config :arbor_agent, skill_library: MyFileSkillLibrary

  Skills are identified by name (string) and can be filtered by category,
  tags, or source when listing and searching.
  """

  alias Arbor.Contracts.Skill

  @type opts :: keyword()

  # --- Required: CRUD + Discovery ---

  @doc """
  Retrieve a skill by its unique name.

  Returns `{:ok, skill}` if found, `{:error, :not_found}` otherwise.
  """
  @callback get(name :: String.t()) :: {:ok, Skill.t()} | {:error, :not_found}

  @doc """
  List skills matching the given filter options.

  ## Options

  - `:category` — filter by category string (e.g., "development")
  - `:tags` — filter by tags; skills must have at least one matching tag
  - `:source` — filter by source atom (e.g., `:builtin`, `:plugin`)

  Returns all skills when no options are provided.
  """
  @callback list(opts()) :: [Skill.t()]

  @doc """
  Search for skills by keyword or semantic query.

  The search strategy depends on the backend — file-based implementations
  may use substring matching on name/description/tags, while pgvector-backed
  implementations can use embedding similarity for natural-language queries.

  ## Options

  - `:limit` — maximum number of results to return
  - `:min_score` — minimum relevance score (for semantic backends)
  - `:category` — restrict search to a specific category

  Returns skills ordered by relevance (most relevant first).
  """
  @callback search(query :: String.t(), opts()) :: [Skill.t()]

  @doc """
  Register a new skill in the library.

  Returns `:ok` on success. Returns `{:error, reason}` if the skill
  is invalid or a skill with the same name already exists (depending
  on the backend's conflict policy).
  """
  @callback register(Skill.t()) :: :ok | {:error, term()}

  @doc """
  Scan a directory and index all skill definitions found.

  Walks the directory tree looking for skill definition files and
  registers each one. The exact file format and discovery strategy
  is backend-specific (e.g., `.skill.exs` files, YAML manifests).

  ## Options

  - `:recursive` — whether to scan subdirectories (default: `true`)
  - `:overwrite` — whether to overwrite existing skills (default: `false`)

  Returns `{:ok, count}` with the number of skills indexed,
  or `{:error, reason}` if the directory cannot be read.
  """
  @callback index(dir :: String.t(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Search for skills using hybrid search (BM25 + pgvector semantic).

  Combines full-text search and vector similarity for more accurate
  skill discovery. Backends that don't support hybrid search should
  fall back to keyword-based search.

  ## Options

  - `:limit` — maximum number of results (default: 10)
  - `:category` — restrict search to a specific category
  - `:taint_filter` — filter by taint level (e.g., `:trusted`)
  - `:min_score` — minimum relevance score threshold

  Returns skills ordered by combined relevance score.
  """
  @callback hybrid_search(query :: String.t(), opts()) :: [Skill.t()]

  @doc """
  Sync all cached skills to a persistent store.

  Writes the current in-memory skill cache to a database or other
  persistent backend for hybrid search indexing.

  Returns `{:ok, count}` with the number of skills synced.
  """
  @callback sync_to_store(opts()) :: {:ok, non_neg_integer()} | {:error, term()}

  @optional_callbacks [hybrid_search: 2, sync_to_store: 1]
end
