defmodule Arbor.Contracts.Security.Sanitizer do
  @moduledoc """
  Behaviour for sanitizer modules that neutralize specific attack vectors.

  Each sanitizer maps to one bit in the `Taint.sanitizations` bitmask.
  A sanitizer validates/transforms data and sets its corresponding bit
  only after successful sanitization — the bit is a promise that the
  sanitizer was applied correctly.

  ## Return Types

  - `{:ok, sanitized_value, updated_taint}` — sanitization succeeded, bit set
  - `{:error, reason}` — sanitization failed or input is too dangerous to sanitize

  ## Detection

  The `detect/1` callback performs detection-only analysis without modifying
  the value or taint. Useful for logging, metrics, and pre-flight checks.
  """

  alias Arbor.Contracts.Security.Taint

  @type result :: {:ok, term(), Taint.t()} | {:error, term()}
  @type detection :: {:safe, score :: float()} | {:unsafe, patterns :: [String.t()]}

  @doc """
  Sanitize a value and set the corresponding bit on the taint struct.

  Returns `{:ok, sanitized_value, updated_taint}` on success.
  Returns `{:error, reason}` if the input is too dangerous to sanitize
  or sanitization fails.

  Options are sanitizer-specific (e.g., `allowed_root:` for path traversal,
  `nonce:` for prompt injection).
  """
  @callback sanitize(value :: term(), taint :: Taint.t(), opts :: keyword()) :: result()

  @doc """
  Detect attack patterns in a value without modifying it.

  Returns `{:safe, score}` where score is 0.0-1.0 (confidence of safety),
  or `{:unsafe, patterns}` with a list of detected attack pattern names.
  """
  @callback detect(value :: term()) :: detection()
end
