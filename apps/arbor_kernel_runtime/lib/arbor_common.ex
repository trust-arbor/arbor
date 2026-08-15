defmodule Arbor.Common do
  @moduledoc """
  Common utilities shared across Arbor applications.

  This library provides reusable utilities for:
  - **Time formatting** - Relative time ("2h ago"), datetime, time-only formats
  - **Pagination** - Cursor-based pagination with timestamp:id cursors
  - **SafeAtom** - DoS-resistant string-to-atom conversion

  ## Usage

      # Time formatting
      Arbor.Common.Time.relative(datetime)  # => "2h ago"
      Arbor.Common.Time.datetime(datetime)  # => "2026-01-26 17:00:00"

      # Pagination
      cursor = Arbor.Common.Pagination.generate_cursor(record)
      {:ok, {timestamp, id}} = Arbor.Common.Pagination.parse_cursor(cursor)

      # Safe atom conversion (DoS prevention)
      Arbor.Common.SafeAtom.to_existing("ok")           # => {:ok, :ok}
      Arbor.Common.SafeAtom.to_allowed("read", [:read]) # => {:ok, :read}
      Arbor.Common.SafeAtom.atomize_keys(map, [:name])  # => %{name: "value"}
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Contracts, Finch, Jason, Logger, Req, Zoi],
    exports: :all

  @doc "Whether the system tool catalog is enabled (default false)."
  @spec tool_catalog_enabled?() :: term()
  def tool_catalog_enabled?, do: Arbor.Common.Config.tool_catalog_enabled?()

  @doc "Whether the system skill catalog is enabled (default false)."
  @spec skill_catalog_enabled?() :: term()
  def skill_catalog_enabled?, do: Arbor.Common.Config.skill_catalog_enabled?()

  @doc "Whether project-context auto-load is enabled (default false)."
  @spec project_context_enabled?() :: term()
  def project_context_enabled?, do: Arbor.Common.Config.project_context_enabled?()
end
