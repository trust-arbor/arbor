defmodule Arbor.Common do
  @moduledoc """
  Common utilities shared across Arbor applications.

  This library provides reusable utilities for:
  - **Time formatting** - Relative time ("2h ago"), datetime, time-only formats
  - **Pagination** - Cursor-based pagination with timestamp:id cursors

  ## Usage

      # Time formatting
      Arbor.Common.Time.relative(datetime)  # => "2h ago"
      Arbor.Common.Time.datetime(datetime)  # => "2026-01-26 17:00:00"

      # Pagination
      cursor = Arbor.Common.Pagination.generate_cursor(record)
      {:ok, {timestamp, id}} = Arbor.Common.Pagination.parse_cursor(cursor)
  """
end
