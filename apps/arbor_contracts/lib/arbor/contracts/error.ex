defmodule Arbor.Contracts.Error do
  @moduledoc """
  TypedStruct for structured, redactable errors.

  A general-purpose error envelope for use across all Arbor domains. Unlike
  the domain-specific `Arbor.Contracts.AI.Error` (which is an Exception with
  retryable semantics), this struct is a **value type** for errors that flow
  through pipelines, checkpoints, signals, and session turns.

  ## Redaction

  Use `redact/1` to strip sensitive detail before logging, transmitting across
  trust boundaries, or persisting to external stores. Once redacted, `detail`
  is cleared and `redacted` is set to `true`. Redaction is idempotent.

  ## Wrapping

  `wrap/2` converts any error term (binary, atom, exception, tuple) into an
  `Arbor.Contracts.Error` struct, making it safe to serialize and inspect
  without pattern-matching on arbitrary shapes.

  ## Usage

      {:ok, err} = Error.new(code: :session_expired, message: "Turn limit reached")
      err.source     # => nil
      err.redacted   # => false

      redacted = Error.redact(err)
      redacted.detail   # => %{}
      redacted.redacted # => true

      wrapped = Error.wrap(:timeout, source: :engine)
      wrapped.code    # => :timeout
      wrapped.message # => "timeout"
      wrapped.source  # => :engine
  """

  use TypedStruct

  @derive {Jason.Encoder, except: []}
  typedstruct enforce: true do
    @typedoc "A structured, redactable error"

    # Required — what happened
    field(:code, atom())
    field(:message, String.t())

    # Origin — which subsystem produced this error
    field(:source, atom() | nil, enforce: false)

    # Contextual detail — cleared on redaction
    field(:detail, map(), default: %{})

    # Redaction flag — set by redact/1
    field(:redacted, boolean(), default: false)

    # When — defaults to utc_now on creation
    field(:timestamp, DateTime.t())

    # Distributed tracing
    field(:trace_id, String.t() | nil, enforce: false)

    # Extensible metadata
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new structured error with validation.

  Accepts a keyword list or map. The `code` and `message` fields are required.

  ## Required Fields

  - `:code` — Error code atom (e.g., `:session_expired`, `:checkpoint_corrupt`)
  - `:message` — Human-readable error description

  ## Optional Fields

  - `:source` — Subsystem that produced the error (e.g., `:engine`, `:session`)
  - `:detail` — Additional error context (default: `%{}`)
  - `:redacted` — Whether the error has been redacted (default: `false`)
  - `:timestamp` — When the error occurred (default: `DateTime.utc_now/0`)
  - `:trace_id` — Distributed trace ID for correlation
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Examples

      {:ok, err} = Error.new(code: :not_found, message: "Session not found")

      {:ok, err} = Error.new(
        code: :validation_failed,
        message: "Invalid checkpoint data",
        source: :checkpoint,
        detail: %{field: :data, reason: "not a map"},
        trace_id: "trace_abc123"
      )

      {:error, {:missing_required, :code}} = Error.new(message: "oops")
      {:error, {:invalid_code, "string"}} = Error.new(code: "string", message: "oops")
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_code(get_attr(attrs, :code)),
         :ok <- validate_message(get_attr(attrs, :message)),
         :ok <- validate_optional_atom(attrs, :source),
         :ok <- validate_optional_map(attrs, :detail),
         :ok <- validate_optional_boolean(attrs, :redacted),
         :ok <- validate_optional_string(attrs, :trace_id),
         :ok <- validate_optional_map(attrs, :metadata) do
      error = %__MODULE__{
        code: get_attr(attrs, :code),
        message: get_attr(attrs, :message),
        source: get_attr(attrs, :source),
        detail: get_attr(attrs, :detail) || %{},
        redacted: get_attr(attrs, :redacted) || false,
        timestamp: get_attr(attrs, :timestamp) || DateTime.utc_now(),
        trace_id: get_attr(attrs, :trace_id),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, error}
    end
  end

  # ============================================================================
  # Operations
  # ============================================================================

  @doc """
  Redact sensitive detail from an error struct.

  Clears the `detail` map and sets `redacted` to `true`. Safe to call
  multiple times (idempotent). The `metadata` map is also cleared since
  it may contain sensitive context.

  ## Examples

      iex> {:ok, err} = Arbor.Contracts.Error.new(
      ...>   code: :auth_failed,
      ...>   message: "Bad credentials",
      ...>   detail: %{token: "secret123"},
      ...>   metadata: %{ip: "10.0.0.1"}
      ...> )
      iex> redacted = Arbor.Contracts.Error.redact(err)
      iex> redacted.detail
      %{}
      iex> redacted.metadata
      %{}
      iex> redacted.redacted
      true
  """
  @spec redact(t()) :: t()
  def redact(%__MODULE__{} = error) do
    %{error | detail: %{}, metadata: %{}, redacted: true}
  end

  @doc """
  Wrap any error term into an `Arbor.Contracts.Error` struct.

  Normalizes arbitrary error shapes (atoms, strings, exceptions, tuples,
  or existing Error structs) into a consistent struct. Useful at boundaries
  where errors from external libraries need to be canonicalized.

  ## Options

  - `:source` — Subsystem that produced the error
  - `:trace_id` — Distributed trace ID
  - `:metadata` — Additional metadata

  ## Examples

      err = Error.wrap(:timeout, source: :engine)
      err.code    # => :timeout
      err.message # => "timeout"
      err.source  # => :engine

      err = Error.wrap("something went wrong")
      err.code    # => :wrapped_error
      err.message # => "something went wrong"

      err = Error.wrap(%RuntimeError{message: "boom"})
      err.code    # => :runtime_error
      err.message # => "boom"

      err = Error.wrap({:invalid_input, "bad data"}, source: :session)
      err.code    # => :invalid_input
      err.message # => "bad data"

      # Already an Error — returns as-is (with opts merged)
      {:ok, existing} = Error.new(code: :test, message: "test")
      err = Error.wrap(existing, source: :session)
      err.source # => :session
  """
  @spec wrap(term(), keyword()) :: t()
  def wrap(error, opts \\ [])

  def wrap(%__MODULE__{} = error, opts) do
    source = Keyword.get(opts, :source)
    trace_id = Keyword.get(opts, :trace_id)
    metadata = Keyword.get(opts, :metadata)

    error
    |> maybe_put(:source, source)
    |> maybe_put(:trace_id, trace_id)
    |> maybe_merge_metadata(metadata)
  end

  def wrap(error, opts) when is_atom(error) do
    build_wrapped(error, Atom.to_string(error), opts)
  end

  def wrap(error, opts) when is_binary(error) do
    build_wrapped(:wrapped_error, error, opts)
  end

  def wrap(%{__exception__: true} = exception, opts) do
    code = exception_to_code(exception)
    message = Exception.message(exception)
    detail = Map.from_struct(exception) |> Map.delete(:__exception__) |> Map.delete(:message)

    build_wrapped(code, message, Keyword.put_new(opts, :detail, detail))
  end

  def wrap({code, message}, opts) when is_atom(code) and is_binary(message) do
    build_wrapped(code, message, opts)
  end

  def wrap({code, detail}, opts) when is_atom(code) do
    build_wrapped(code, Atom.to_string(code), Keyword.put_new(opts, :detail, %{reason: detail}))
  end

  def wrap(other, opts) do
    build_wrapped(:wrapped_error, inspect(other), opts)
  end

  # ============================================================================
  # Private — Wrapped Construction
  # ============================================================================

  defp build_wrapped(code, message, opts) do
    %__MODULE__{
      code: code,
      message: message,
      source: Keyword.get(opts, :source),
      detail: Keyword.get(opts, :detail, %{}),
      redacted: false,
      timestamp: DateTime.utc_now(),
      trace_id: Keyword.get(opts, :trace_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp exception_to_code(%{__struct__: module}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp maybe_put(error, _key, nil), do: error
  defp maybe_put(error, key, value), do: Map.put(error, key, value)

  defp maybe_merge_metadata(error, nil), do: error

  defp maybe_merge_metadata(error, metadata) when is_map(metadata) do
    %{error | metadata: Map.merge(error.metadata, metadata)}
  end

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_code(nil), do: {:error, {:missing_required, :code}}
  defp validate_code(code) when is_atom(code), do: :ok
  defp validate_code(code), do: {:error, {:invalid_code, code}}

  defp validate_message(nil), do: {:error, {:missing_required, :message}}
  defp validate_message(msg) when is_binary(msg) and byte_size(msg) > 0, do: :ok
  defp validate_message(msg), do: {:error, {:invalid_message, msg}}

  defp validate_optional_atom(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_atom(val) -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  defp validate_optional_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_binary(val) -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  defp validate_optional_map(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_map(val) -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  defp validate_optional_boolean(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_boolean(val) -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

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
