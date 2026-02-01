defmodule Arbor.Flow do
  @moduledoc """
  Pure workflow utilities for Arbor.

  This Level 0 library provides:

  - `Arbor.Flow.ItemParser` - Markdown parsing and serialization for workflow items
  - `Arbor.Flow.IndexManager` - INDEX.md generation and maintenance
  - `Arbor.Flow.Watcher` - GenServer for watching directories and detecting changes
  - `Arbor.Flow.FileTracker` - Behaviour for tracking processed files

  ## Design Principles

  arbor_flow is a pure utility library with zero umbrella dependencies. It:

  - Returns plain maps from ItemParser (struct wrapping happens in consumers)
  - Defines behaviours for extension (FileTracker, Watcher callbacks)
  - Uses standard Elixir patterns (GenServer, ETS)
  - Has no external service dependencies

  ## Usage

  ```elixir
  # Parse markdown into a map
  {:ok, item_map} = Arbor.Flow.ItemParser.parse_file("roadmap/0-inbox/feature.md")

  # Serialize back to markdown
  markdown = Arbor.Flow.ItemParser.serialize(item_map)

  # Generate an index
  Arbor.Flow.IndexManager.refresh("roadmap", stages: [:inbox, :planned, :completed])
  ```

  Higher-level libraries (arbor_sdlc) consume these utilities and add:

  - Contract struct wrapping (Arbor.Contracts.Flow.Item)
  - AI-powered processing
  - Persistence-backed file tracking
  - Signal emission for observability
  """

  @doc """
  Compute a content hash for change detection.

  Uses SHA-256 truncated to 16 hex characters.
  """
  @spec compute_hash(String.t()) :: String.t()
  def compute_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
