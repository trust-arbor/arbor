defmodule Arbor.Common.Sanitizers.SQL do
  @moduledoc """
  Sanitizer for SQL injection attacks.

  Validates dynamic identifiers via allowlists, escapes LIKE patterns,
  and detects SQL injection patterns. Sets bit 1 on the taint
  sanitizations bitmask after successful sanitization.

  **This is NOT a replacement for parameterized queries.** This sanitizer
  handles the cases where parameterization isn't possible: dynamic
  identifiers (table/column names) and LIKE patterns.

  ## Options

  - `:allowed_identifiers` — allowlist for dynamic identifiers (required for
    identifier sanitization mode)
  - `:mode` — `:identifier` or `:like_pattern` (default: `:like_pattern`)
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Common.SafeAtom
  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b00000010

  # SQL injection detection patterns
  @sqli_patterns [
    {~r/--/, "sql_comment_dash"},
    {~r{/\*}, "sql_comment_block"},
    {~r/;\s*(?:DROP|DELETE|UPDATE|INSERT|ALTER|CREATE|EXEC|UNION)/i, "stacked_query"},
    {~r/\bUNION\b.*\bSELECT\b/is, "union_select"},
    {~r/\bOR\b\s+\d+\s*=\s*\d+/i, "tautology"},
    {~r/\bOR\b\s+'[^']*'\s*=\s*'[^']*'/i, "string_tautology"},
    {~r/'\s*(?:OR|AND)\s/i, "quote_boolean"},
    {~r/\bDROP\b\s+\bTABLE\b/i, "drop_table"},
    {~r/\bxp_/i, "extended_stored_proc"},
    {~r/\bEXEC(?:UTE)?\b/i, "exec_command"},
    {~r/\bINTO\b\s+\b(?:OUT|DUMP)FILE\b/i, "file_write"},
    {~r/\bLOAD_FILE\b/i, "file_read"},
    {~r/\bSLEEP\b\s*\(/i, "time_based"},
    {~r/\bBENCHMARK\b\s*\(/i, "time_based"},
    {~r/\bWAITFOR\b\s+\bDELAY\b/i, "time_based"},
    {~r/'\s*;\s*$/i, "trailing_semicolon"}
  ]

  @impl true
  @spec sanitize(term(), Taint.t(), keyword()) ::
          {:ok, String.t(), Taint.t()} | {:error, term()}
  def sanitize(value, %Taint{} = taint, opts \\ []) when is_binary(value) do
    mode = Keyword.get(opts, :mode, :like_pattern)

    case mode do
      :identifier -> sanitize_identifier(value, taint, opts)
      :like_pattern -> sanitize_like_pattern(value, taint)
    end
  end

  @impl true
  @spec detect(term()) :: {:safe, float()} | {:unsafe, [String.t()]}
  def detect(value) when is_binary(value) do
    found =
      Enum.flat_map(@sqli_patterns, fn {pattern, name} ->
        if Regex.match?(pattern, value), do: [name], else: []
      end)

    case found do
      [] -> {:safe, 1.0}
      patterns -> {:unsafe, patterns}
    end
  end

  def detect(_), do: {:safe, 1.0}

  @doc """
  Escape LIKE metacharacters so user input is matched literally.

  This is the same logic used in `Arbor.Persistence.QueryableStore.Postgres`
  but reimplemented here since arbor_common cannot depend on arbor_persistence.
  """
  @spec escape_like_pattern(String.t()) :: String.t()
  def escape_like_pattern(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # -- Private ---------------------------------------------------------------

  defp sanitize_identifier(value, taint, opts) do
    case Keyword.fetch(opts, :allowed_identifiers) do
      {:ok, allowed} ->
        case SafeAtom.to_allowed(value, allowed) do
          {:ok, _atom} ->
            updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
            {:ok, value, updated_taint}

          {:error, _} ->
            {:error, {:identifier_not_allowed, value}}
        end

      :error ->
        {:error, {:missing_option, :allowed_identifiers}}
    end
  end

  defp sanitize_like_pattern(value, taint) do
    escaped = escape_like_pattern(value)
    updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
    {:ok, escaped, updated_taint}
  end
end
