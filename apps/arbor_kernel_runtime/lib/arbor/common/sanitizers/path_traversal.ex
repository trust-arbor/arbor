defmodule Arbor.Common.Sanitizers.PathTraversal do
  @moduledoc """
  Sanitizer for path traversal attacks.

  Wraps `Arbor.Common.SafePath.resolve_within/2` and sets bit 3 on the
  taint sanitizations bitmask after successful sanitization.

  Requires `allowed_root:` option — there is no safe default.

  ## Attack Vectors Detected

  - Literal `..` traversal sequences
  - URL-encoded traversal (`%2e%2e`, `%252e`)
  - Null bytes (truncate paths in C-based parsers)
  - Windows path separators (`\\`)
  - Encoded separators (`%2f`, `%5c`)
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b00001000

  @impl true
  @spec sanitize(term(), Taint.t(), keyword()) ::
          {:ok, String.t(), Taint.t()} | {:error, term()}
  def sanitize(value, %Taint{} = taint, opts) when is_binary(value) do
    case Keyword.fetch(opts, :allowed_root) do
      {:ok, root} ->
        case SafePath.resolve_within(value, root) do
          {:ok, resolved} ->
            updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
            {:ok, resolved, updated_taint}

          {:error, reason} ->
            {:error, {:path_traversal, reason}}
        end

      :error ->
        {:error, {:missing_option, :allowed_root}}
    end
  end

  @impl true
  @spec detect(term()) :: {:safe, float()} | {:unsafe, [String.t()]}
  def detect(value) when is_binary(value) do
    found = detect_patterns(value)

    case found do
      [] -> {:safe, 1.0}
      patterns -> {:unsafe, patterns}
    end
  end

  def detect(_), do: {:safe, 1.0}

  defp detect_patterns(value) do
    lowered = String.downcase(value)

    checks = [
      {String.contains?(value, ".."), "dot_dot_traversal"},
      {String.contains?(value, <<0>>), "null_byte"},
      {String.contains?(value, "\\"), "windows_separator"},
      {String.contains?(lowered, "%2e%2e"), "url_encoded_traversal"},
      {String.contains?(lowered, "%252e"), "double_encoded_traversal"},
      {String.contains?(lowered, "%2f"), "encoded_forward_slash"},
      {String.contains?(lowered, "%5c"), "encoded_backslash"},
      {String.contains?(lowered, "%00"), "encoded_null_byte"},
      {String.contains?(value, "~"), "home_dir_reference"}
    ]

    for {true, name} <- checks, do: name
  end
end
