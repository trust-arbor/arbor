defmodule Arbor.Agent.ContextManager do
  @moduledoc """
  Manages context window lifecycle for agents.

  Handles:
  - Creation with configurable presets
  - Persistence to JSON files
  - Restoration on startup
  - Compression detection

  Context windows are persisted as JSON files in the configured
  directory (default: `~/.arbor/context_windows/`).
  """

  alias Arbor.Agent.ContextSummarizer
  alias Arbor.Memory

  require Logger

  @doc """
  Create or restore a context window for an agent.

  Tries to restore from persistence first. If not found, creates a new
  window using the specified preset.

  ## Options

  - `:preset` - Context preset to use (`:balanced`, `:conservative`, `:expansive`)
  - `:max_tokens` - Override max tokens
  - `:summary_threshold` - Override summary threshold
  """
  @spec init_context(String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def init_context(agent_id, opts \\ []) do
    case restore_context(agent_id) do
      {:ok, window} ->
        Logger.info("Restored context window",
          agent_id: agent_id,
          entries: entry_count(window)
        )

        {:ok, window}

      {:error, :not_found} ->
        preset = Keyword.get(opts, :preset, config(:default_preset, :balanced))
        {:ok, create_context(agent_id, preset, opts)}

      {:error, reason} ->
        Logger.warning("Failed to restore context, creating new",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        {:ok, create_context(agent_id, :balanced, opts)}
    end
  end

  @doc """
  Create a new context window with a preset.

  ## Presets

  - `:balanced` - 10k max tokens, 0.7 summarization threshold
  - `:conservative` - 5k max tokens, 0.6 summarization threshold
  - `:expansive` - 50k max tokens, 0.8 summarization threshold
  """
  @spec create_context(String.t(), atom(), keyword()) :: struct()
  def create_context(agent_id, preset, opts \\ []) do
    presets = config(:context_presets, default_presets())
    preset_config = Map.get(presets, preset, presets[:balanced])

    # Keyword opts override preset values
    max_tokens = Keyword.get(opts, :max_tokens, preset_config[:max_tokens])
    threshold = Keyword.get(opts, :summary_threshold, preset_config[:summary_threshold])

    if context_window_available?() do
      Memory.new_context_window(agent_id,
        max_tokens: max_tokens,
        summary_threshold: threshold
      )
    else
      # Fallback: plain map if ContextWindow module unavailable
      %{
        agent_id: agent_id,
        entries: [],
        max_tokens: max_tokens,
        summary_threshold: threshold
      }
    end
  end

  @doc """
  Restore context from persistence (JSON file).
  """
  @spec restore_context(String.t()) :: {:ok, struct()} | {:error, term()}
  def restore_context(agent_id) do
    if config(:context_persistence_enabled, true) do
      do_restore_context(agent_id)
    else
      {:error, :persistence_disabled}
    end
  end

  defp do_restore_context(agent_id) do
    path = context_window_path(agent_id)

    with {:ok, json} <- read_context_file(path),
         {:ok, data} when is_map(data) <- Jason.decode(json) do
      deserialize_context(data)
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:json_decode, reason}}
    end
  end

  defp read_context_file(path) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  defp deserialize_context(data) do
    if context_window_available?() do
      {:ok, Memory.deserialize_context_window(data)}
    else
      {:ok, data}
    end
  end

  @doc """
  Save context to persistence (JSON file).
  """
  @spec save_context(String.t(), struct() | map()) :: :ok | {:error, term()}
  def save_context(agent_id, window) do
    if config(:context_persistence_enabled, true) do
      path = context_window_path(agent_id)
      dir = Path.dirname(path)

      with :ok <- File.mkdir_p(dir) do
        serialized =
          if context_window_available?() and is_struct(window, Arbor.Memory.ContextWindow) do
            Memory.serialize_context_window(window)
          else
            window
          end

        case Jason.encode(serialized) do
          {:ok, json} -> File.write(path, json)
          {:error, reason} -> {:error, {:json_encode, reason}}
        end
      end
    else
      :ok
    end
  end

  @doc """
  Check if context window should be compressed/summarized.
  """
  @spec should_compress?(struct() | map()) :: boolean()
  def should_compress?(window) do
    if config(:context_compression_enabled, true) do
      if context_window_available?() and is_struct(window, Arbor.Memory.ContextWindow) do
        Memory.context_should_summarize?(window)
      else
        false
      end
    else
      false
    end
  end

  @doc """
  Compress context using intelligent summarization if enabled,
  falling back to simple truncation.

  Uses `Arbor.Agent.ContextSummarizer` for dual-model summarization
  when `context_summarization_enabled` is true.
  """
  @spec maybe_compress(map()) :: {:ok, map()} | {:error, term()}
  def maybe_compress(window) do
    if config(:context_summarization_enabled, false) do
      ContextSummarizer.maybe_summarize(window)
    else
      {:ok, window}
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp entry_count(window) when is_struct(window) do
    if context_window_available?() do
      Memory.context_entry_count(window)
    else
      0
    end
  end

  defp entry_count(window) when is_map(window) do
    window |> Map.get(:entries, []) |> length()
  end

  defp entry_count(_), do: 0

  defp context_window_available? do
    Code.ensure_loaded?(Arbor.Memory.ContextWindow) and
      function_exported?(Arbor.Memory.ContextWindow, :new, 2)
  end

  defp context_window_path(agent_id) do
    base = config(:context_window_dir, "~/.arbor/context_windows")
    safe_id = String.replace(agent_id, ~r/[^a-zA-Z0-9_-]/, "_")
    Path.expand(base) |> Path.join("#{safe_id}.json")
  end

  defp default_presets do
    %{
      balanced: [
        max_tokens: 10_000,
        summary_threshold: 0.7
      ],
      conservative: [
        max_tokens: 5_000,
        summary_threshold: 0.6
      ],
      expansive: [
        max_tokens: 50_000,
        summary_threshold: 0.8
      ]
    }
  end

  defp config(key, default) do
    Application.get_env(:arbor_agent, key, default)
  end
end
