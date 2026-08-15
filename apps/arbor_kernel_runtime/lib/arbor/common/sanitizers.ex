defmodule Arbor.Common.Sanitizers do
  @moduledoc """
  Facade for all sanitizer modules.

  Routes sanitization requests to the correct module based on the
  sanitizer type atom. Supports chaining multiple sanitizers.

  ## Usage

      alias Arbor.Contracts.Security.Taint

      taint = %Taint{level: :untrusted}

      # Single sanitizer
      {:ok, safe_path, updated_taint} =
        Sanitizers.sanitize(:path_traversal, user_path, taint, allowed_root: "/data")

      # Chain multiple sanitizers
      {:ok, safe_value, updated_taint} =
        Sanitizers.sanitize_all([:xss, :log_injection], user_input, taint)

      # Detection only (no taint modification)
      {:unsafe, patterns} = Sanitizers.detect(:sqli, "'; DROP TABLE users--")

      # Check if already sanitized
      false = Sanitizers.needs_sanitization?(taint, :command_injection)
  """

  alias Arbor.Contracts.Security.Taint

  @type result :: {:ok, term(), Taint.t()} | {:error, term()}

  @modules %{
    xss: Arbor.Common.Sanitizers.XSS,
    sqli: Arbor.Common.Sanitizers.SQL,
    command_injection: Arbor.Common.Sanitizers.CommandInjection,
    path_traversal: Arbor.Common.Sanitizers.PathTraversal,
    prompt_injection: Arbor.Common.Sanitizers.PromptInjection,
    ssrf: Arbor.Common.Sanitizers.SSRF,
    log_injection: Arbor.Common.Sanitizers.LogInjection,
    deserialization: Arbor.Common.Sanitizers.Deserialization
  }

  @doc """
  Apply a specific sanitizer to a value with its taint.

  Returns `{:ok, sanitized_value, updated_taint}` on success.
  Returns `{:error, reason}` on failure or unknown sanitizer type.
  """
  @spec sanitize(atom(), term(), Taint.t(), keyword()) :: result()
  def sanitize(type, value, %Taint{} = taint, opts \\ []) do
    case Map.get(@modules, type) do
      nil -> {:error, {:unknown_sanitizer, type}}
      module -> module.sanitize(value, taint, opts)
    end
  end

  @doc """
  Apply multiple sanitizers in sequence.

  Chains sanitizers left-to-right: the output of one becomes
  the input of the next. Stops on first error.
  """
  @spec sanitize_all([atom()], term(), Taint.t(), keyword()) :: result()
  def sanitize_all(types, value, %Taint{} = taint, opts \\ []) do
    Enum.reduce_while(types, {:ok, value, taint}, fn type, {:ok, val, t} ->
      case sanitize(type, val, t, opts) do
        {:ok, new_val, new_taint} -> {:cont, {:ok, new_val, new_taint}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Check if a value still needs sanitization for a given type.

  Returns `true` if the sanitization bit is NOT set on the taint.
  """
  @spec needs_sanitization?(Taint.t(), atom()) :: boolean()
  def needs_sanitization?(%Taint{sanitizations: mask}, type) do
    case Taint.sanitization_bit(type) do
      {:ok, bit} -> Bitwise.band(mask, bit) == 0
      :error -> true
    end
  end

  @doc """
  Detect attack patterns without modifying the value or taint.

  Returns `{:safe, score}` or `{:unsafe, patterns}`.
  Returns `{:error, {:unknown_sanitizer, type}}` for unknown types.
  """
  @spec detect(atom(), term()) ::
          {:safe, float()} | {:unsafe, [String.t()]} | {:error, term()}
  def detect(type, value) do
    case Map.get(@modules, type) do
      nil -> {:error, {:unknown_sanitizer, type}}
      module -> module.detect(value)
    end
  end

  @doc """
  Return all known sanitizer types.
  """
  @spec types() :: [atom()]
  def types, do: Map.keys(@modules)

  @doc """
  Return the module for a given sanitizer type.
  """
  @spec module_for(atom()) :: {:ok, module()} | :error
  def module_for(type) do
    case Map.get(@modules, type) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end
end
