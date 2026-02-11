defmodule Arbor.Contracts.AI.Error do
  @moduledoc """
  Structured AI/LLM error with Exception behaviour.

  Represents a typed, retryable-aware error from an LLM provider. Implements
  the `Exception` behaviour so it can be raised directly or matched in
  `{:error, %AI.Error{}}` tuples.

  ## Retryable Codes

  The following error codes are considered retryable by default:

  - `:rate_limited` — Provider rate limit hit, back off and retry
  - `:timeout` — Request timed out, retry with same or different provider
  - `:provider_error` — Transient provider-side failure

  ## Redaction

  Use `redact/1` to strip sensitive detail before logging or transmitting
  error structs across trust boundaries. Once redacted, the `detail` map
  is cleared and `redacted` is set to `true`.

  ## Usage

      {:ok, err} = AI.Error.new(code: :rate_limited, message: "429 Too Many Requests", provider: "anthropic")
      err.retryable?   # => true (auto-set for known retryable codes)

      redacted = AI.Error.redact(err)
      redacted.detail  # => %{}
      redacted.redacted # => true

      raise AI.Error, code: :invalid_model, message: "Model not found"
  """

  @retryable_codes [:rate_limited, :timeout, :provider_error]

  @typedoc "A structured AI/LLM error"
  @type t :: %__MODULE__{
          __exception__: true,
          code: atom(),
          message: String.t(),
          provider: String.t() | nil,
          retryable?: boolean(),
          detail: map(),
          redacted: boolean(),
          request_id: String.t() | nil
        }

  @derive {Jason.Encoder, except: [:__exception__]}
  defexception [
    :code,
    :message,
    :provider,
    {:retryable?, false},
    {:detail, %{}},
    {:redacted, false},
    :request_id
  ]

  # ============================================================================
  # Exception Behaviour
  # ============================================================================

  @doc """
  Creates a new `AI.Error` exception from keyword attributes.

  Used by `raise/2`. Delegates to `new!/1` for construction.

  ## Examples

      raise Arbor.Contracts.AI.Error, code: :timeout, message: "Request timed out"
  """
  @impl true
  def exception(attrs) when is_list(attrs) do
    new!(attrs)
  end

  def exception(msg) when is_binary(msg) do
    new!(code: :unknown, message: msg)
  end

  @doc """
  Returns the error message string.

  ## Examples

      iex> {:ok, err} = Arbor.Contracts.AI.Error.new(code: :timeout, message: "Timed out")
      iex> Exception.message(err)
      "Timed out"
  """
  @impl true
  def message(%__MODULE__{message: msg}), do: msg

  # ============================================================================
  # Public — Construction
  # ============================================================================

  @doc """
  Create a new AI error with validation.

  Accepts keyword list or map. Automatically sets `retryable?` to `true`
  for codes in `retryable_codes/0` unless explicitly overridden.

  ## Required Fields

  - `:code` — Error code atom (e.g., `:rate_limited`, `:timeout`, `:invalid_model`)
  - `:message` — Human-readable error description

  ## Optional Fields

  - `:provider` — Provider that produced the error
  - `:retryable?` — Whether the error is retryable (auto-set for known codes)
  - `:detail` — Additional error context (default: `%{}`)
  - `:redacted` — Whether the error has been redacted (default: `false`)
  - `:request_id` — Correlating request ID

  ## Examples

      {:ok, err} = AI.Error.new(code: :rate_limited, message: "429")
      err.retryable?  # => true

      {:ok, err} = AI.Error.new(code: :invalid_model, message: "Not found")
      err.retryable?  # => false

      {:error, {:missing_required_field, :code}} = AI.Error.new(message: "oops")
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs, [:code, :message]),
         :ok <- validate_code(get_attr(attrs, :code)),
         :ok <- validate_message(get_attr(attrs, :message)),
         :ok <- validate_detail(get_attr(attrs, :detail)) do
      code = get_attr(attrs, :code)
      explicit_retryable = get_attr(attrs, :retryable?)

      retryable =
        case explicit_retryable do
          nil -> code in @retryable_codes
          val when is_boolean(val) -> val
          _ -> false
        end

      error = %__MODULE__{
        code: code,
        message: get_attr(attrs, :message),
        provider: get_attr(attrs, :provider),
        retryable?: retryable,
        detail: get_attr(attrs, :detail) || %{},
        redacted: get_attr(attrs, :redacted) || false,
        request_id: get_attr(attrs, :request_id)
      }

      {:ok, error}
    end
  end

  @doc """
  Like `new/1` but returns the struct directly or raises on invalid input.

  ## Examples

      err = AI.Error.new!(code: :timeout, message: "Timed out")
      err.code  # => :timeout
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, error} -> error
      {:error, reason} -> raise ArgumentError, "invalid AI.Error: #{inspect(reason)}"
    end
  end

  # ============================================================================
  # Public — Operations
  # ============================================================================

  @doc """
  Redact sensitive detail from an error struct.

  Clears the `detail` map and sets `redacted` to `true`. Safe to call
  multiple times (idempotent).

  ## Examples

      iex> {:ok, err} = Arbor.Contracts.AI.Error.new(
      ...>   code: :provider_error,
      ...>   message: "Internal error",
      ...>   detail: %{raw_body: "secret data"}
      ...> )
      iex> redacted = Arbor.Contracts.AI.Error.redact(err)
      iex> redacted.detail
      %{}
      iex> redacted.redacted
      true
  """
  @spec redact(t()) :: t()
  def redact(%__MODULE__{} = error) do
    %{error | detail: %{}, redacted: true}
  end

  @doc """
  Returns the list of error codes considered retryable by default.

  ## Examples

      iex> Arbor.Contracts.AI.Error.retryable_codes()
      [:rate_limited, :timeout, :provider_error]
  """
  @spec retryable_codes() :: [atom()]
  def retryable_codes, do: @retryable_codes

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_required(attrs, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      if get_attr(attrs, key) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing_required_field, key}}}
      end
    end)
  end

  defp validate_code(code) when is_atom(code), do: :ok
  defp validate_code(code), do: {:error, {:invalid_code, code}}

  defp validate_message(msg) when is_binary(msg) and msg != "", do: :ok
  defp validate_message(msg), do: {:error, {:invalid_message, msg}}

  defp validate_detail(nil), do: :ok
  defp validate_detail(detail) when is_map(detail), do: :ok
  defp validate_detail(detail), do: {:error, {:invalid_detail, detail}}

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
