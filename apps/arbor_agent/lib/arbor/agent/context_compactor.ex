defmodule Arbor.Agent.ContextCompactor do
  @moduledoc """
  Progressive forgetting for long-running agent loops.

  Maintains a shadow context (full_transcript) alongside a projected view
  (llm_messages) that the LLM actually sees. Compaction modifies ONLY the
  projected view — the full transcript is append-only.

  ## Compaction Pipeline

  When token usage approaches the effective window, messages are processed
  oldest-first through a continuous-decay pipeline:

  1. **Semantic squashing** — superseded tool calls compressed (same file read twice)
  2. **Omission with pointer** — old file reads become stubs with re-read instructions
  3. **Heuristic distillation** — old tool results compressed to one-liners
  4. **LLM narrative summary** (optional) — batch old turns into a narrative paragraph

  Each message gets a `detail_level` from its position: 1.0 (newest) → 0.0 (oldest).
  This is a continuous gradient, not discrete tiers.

  ## File Index

  Side-channel tracking all files seen, with content hashes. When a file is re-read
  with unchanged content, the result is replaced with a pointer.

  ## Usage

      compactor = ContextCompactor.new(model: "claude-3-5-haiku-latest")
      compactor = ContextCompactor.append(compactor, %{role: :user, content: "..."})
      compactor = ContextCompactor.maybe_compact(compactor)
      messages = ContextCompactor.llm_messages(compactor)
  """

  @behaviour Arbor.Contracts.AI.Compactor

  require Logger

  @chars_per_token 4
  @compaction_threshold 0.75
  @default_effective_window 75_000

  # Tool names that represent file reads
  @file_read_tools ~w(file_read file.read)
  @file_write_tools ~w(file_write file.write file_edit file.edit)

  # Tool names for memory/relationship operations
  @memory_read_tools ~w(memory_recall memory_read_self memory_reflect
    memory_introspect relationship_get relationship_browse relationship_summarize)

  @memory_write_tools ~w(memory_remember memory_add_insight memory_connect
    relationship_save relationship_moment)

  defstruct [
    :effective_window,
    :config,
    full_transcript: [],
    llm_messages: [],
    file_index: %{},
    memory_index: %{},
    token_count: 0,
    peak_tokens: 0,
    turn: 0,
    compression_count: 0,
    squash_count: 0,
    narrative_count: 0
  ]

  @type file_entry :: %{
          content_hash: String.t(),
          last_seen_turn: non_neg_integer(),
          line_count: non_neg_integer(),
          summary: String.t() | nil,
          modules: [String.t()],
          key_functions: [String.t()]
        }

  @type memory_entry :: %{
          content_hash: String.t(),
          last_seen_turn: non_neg_integer(),
          person_names: [String.t()],
          emotional_markers: [String.t()],
          relationship_dynamics: [String.t()],
          values: [String.t()],
          self_knowledge_categories: %{String.t() => non_neg_integer()},
          query: String.t() | nil
        }

  @type config :: %{
          effective_window: non_neg_integer(),
          compaction_model: String.t() | nil,
          compaction_provider: atom() | nil,
          enable_llm_compaction: boolean()
        }

  @type t :: %__MODULE__{
          full_transcript: [map()],
          llm_messages: [map()],
          file_index: %{String.t() => file_entry()},
          memory_index: %{String.t() => memory_entry()},
          token_count: non_neg_integer(),
          peak_tokens: non_neg_integer(),
          effective_window: non_neg_integer(),
          turn: non_neg_integer(),
          compression_count: non_neg_integer(),
          squash_count: non_neg_integer(),
          narrative_count: non_neg_integer(),
          config: config()
        }

  # ── Public API ───────────────────────────────────────────────────

  @doc """
  Create a new compactor with model-aware effective window.

  ## Options

    * `:model` - Model ID for context window lookup
    * `:effective_window` - Override effective window (tokens)
    * `:enable_llm_compaction` - Enable LLM narrative summaries (default: false)
    * `:compaction_model` - Model for narrative summaries
    * `:compaction_provider` - Provider for narrative summaries
  """
  @impl Arbor.Contracts.AI.Compactor
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    model = Keyword.get(opts, :model)
    explicit_window = Keyword.get(opts, :effective_window)

    effective_window =
      cond do
        explicit_window -> explicit_window
        model -> trunc(model_context_size(model) * @compaction_threshold)
        true -> @default_effective_window
      end

    config = %{
      effective_window: effective_window,
      compaction_model: Keyword.get(opts, :compaction_model, "anthropic/claude-3-5-haiku-latest"),
      compaction_provider: Keyword.get(opts, :compaction_provider, :openrouter),
      enable_llm_compaction: Keyword.get(opts, :enable_llm_compaction, false)
    }

    %__MODULE__{
      effective_window: effective_window,
      config: config
    }
  end

  @doc """
  Append a message to both full_transcript and llm_messages.

  Updates incremental token count and file index for tool results.
  """
  @impl Arbor.Contracts.AI.Compactor
  @spec append(t(), map()) :: t()
  def append(%__MODULE__{} = compactor, message) do
    # Dedup check BEFORE updating index — otherwise the new content
    # overwrites the index and always matches itself
    message = maybe_deduplicate_file_read(compactor, message)

    compactor =
      compactor
      |> maybe_update_file_index(message)
      |> maybe_update_memory_index(message)

    msg_tokens = estimate_tokens(message)
    new_token_count = compactor.token_count + msg_tokens
    new_peak = max(compactor.peak_tokens, new_token_count)

    %{
      compactor
      | full_transcript: compactor.full_transcript ++ [message],
        llm_messages: compactor.llm_messages ++ [message],
        token_count: new_token_count,
        peak_tokens: new_peak,
        turn: compactor.turn + 1
    }
  end

  @doc """
  Run compaction if token usage approaches the effective window.

  Returns the compactor unchanged if below threshold. Compaction modifies
  ONLY `llm_messages` — `full_transcript` is never touched.
  """
  @impl Arbor.Contracts.AI.Compactor
  @spec maybe_compact(t()) :: t()
  def maybe_compact(%__MODULE__{} = compactor) do
    if needs_compaction?(compactor) do
      compact(compactor)
    else
      compactor
    end
  end

  @doc """
  Returns the projected message view for LLM calls.
  """
  @impl Arbor.Contracts.AI.Compactor
  @spec llm_messages(t()) :: [map()]
  def llm_messages(%__MODULE__{llm_messages: msgs}), do: msgs

  @doc """
  Returns the full, unmodified transcript.
  """
  @impl Arbor.Contracts.AI.Compactor
  @spec full_transcript(t()) :: [map()]
  def full_transcript(%__MODULE__{full_transcript: transcript}), do: transcript

  @doc """
  Returns compaction statistics.
  """
  @impl Arbor.Contracts.AI.Compactor
  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = c) do
    total_turns = length(c.full_transcript)
    reasoning_tokens = c.token_count

    %{
      token_count: c.token_count,
      peak_tokens: c.peak_tokens,
      effective_window: c.effective_window,
      full_transcript_length: total_turns,
      llm_messages_length: length(c.llm_messages),
      compression_count: c.compression_count,
      squash_count: c.squash_count,
      narrative_count: c.narrative_count,
      file_index_size: map_size(c.file_index),
      memory_index_size: map_size(c.memory_index),
      turn: c.turn,
      token_roi: token_roi(reasoning_tokens, c.compression_count)
    }
  end

  # ── Compaction ─────────────────────────────────────────────────

  defp needs_compaction?(%{token_count: count, effective_window: window}) do
    count >= window * @compaction_threshold
  end

  defp compact(compactor) do
    messages = compactor.llm_messages
    total = length(messages)

    if total <= 2 do
      # Nothing to compact — just system + user
      compactor
    else
      {compacted, stats} = run_compaction_pipeline(messages, total, compactor)

      new_token_count = count_all_tokens(compacted)

      %{
        compactor
        | llm_messages: compacted,
          token_count: new_token_count,
          compression_count: compactor.compression_count + stats.compressions,
          squash_count: compactor.squash_count + stats.squashes,
          narrative_count: compactor.narrative_count + stats.narratives
      }
    end
  end

  defp run_compaction_pipeline(messages, total, compactor) do
    stats = %{compressions: 0, squashes: 0, narratives: 0}

    # Step 1: Semantic squashing — find superseded tool calls (file + memory)
    {messages, stats} = semantic_squash(messages, total, stats, compactor.memory_index)

    # Step 2-3: Apply detail-level-based compression (enriched with file + memory index)
    {messages, stats} =
      apply_detail_decay(messages, total, stats, compactor.file_index, compactor.memory_index)

    # Step 4: Optional LLM narrative for very old turns
    {messages, stats} =
      if compactor.config.enable_llm_compaction do
        apply_llm_narrative(messages, total, compactor.config, stats)
      else
        {messages, stats}
      end

    {messages, stats}
  end

  # ── Step 1: Semantic Squashing ─────────────────────────────────

  defp semantic_squash(messages, _total, stats, memory_index) do
    # Find file reads where the same file was read again later.
    # The earlier read is superseded and can be compressed.
    file_read_indices = find_file_read_indices(messages)

    # Find memory reads where the same person/query was looked up again later
    # with identical content (same content_hash in memory_index)
    memory_read_indices = find_memory_read_indices(messages, memory_index)

    # Group by key (path for files, person/query for memory) — keep only the latest
    superseded =
      (file_read_indices ++ memory_read_indices)
      |> Enum.group_by(fn {_idx, key} -> key end)
      |> Enum.flat_map(fn {_key, entries} ->
        if length(entries) > 1 do
          entries |> Enum.sort_by(fn {idx, _} -> idx end) |> Enum.drop(-1)
        else
          []
        end
      end)
      |> Enum.map(fn {idx, _key} -> idx end)
      |> MapSet.new()

    if MapSet.size(superseded) == 0 do
      {messages, stats}
    else
      squashed =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          if idx in superseded do
            squash_tool_result(msg)
          else
            msg
          end
        end)

      {squashed, %{stats | squashes: stats.squashes + MapSet.size(superseded)}}
    end
  end

  defp find_file_read_indices(messages) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn {msg, idx} ->
      case extract_tool_file_path(msg) do
        {:read, path} -> [{idx, path}]
        _ -> []
      end
    end)
  end

  defp extract_tool_file_path(%{role: :tool, name: name, content: content})
       when is_binary(name) do
    if name in @file_read_tools do
      # Try to extract file path from content or the message itself
      path = extract_path_from_content(content)
      if path, do: {:read, path}, else: nil
    else
      nil
    end
  end

  defp extract_tool_file_path(%{role: :tool} = msg) do
    name = to_string(Map.get(msg, :name, ""))

    if name in @file_read_tools do
      path = extract_path_from_content(Map.get(msg, :content, ""))
      if path, do: {:read, path}, else: nil
    else
      nil
    end
  end

  defp extract_tool_file_path(_), do: nil

  defp extract_path_from_content(content) when is_binary(content) do
    cond do
      # JSON format: {"path": "...", "content": "..."} — from action modules
      String.starts_with?(content, "{") ->
        case Jason.decode(content) do
          {:ok, %{"path" => path}} when is_binary(path) -> path
          _ -> nil
        end

      # Plain text: path on first line
      String.match?(content, ~r"^(\/|\.\/|apps\/|lib\/)") ->
        content |> String.split("\n", parts: 2) |> List.first() |> String.trim()

      # "File: path" pattern
      match = Regex.run(~r"File:\s*(.+?)(?:\n|$)", content) ->
        Enum.at(match, 1) |> String.trim()

      true ->
        nil
    end
  end

  defp extract_path_from_content(_), do: nil

  defp squash_tool_result(%{role: :tool} = msg) do
    name = Map.get(msg, :name, "unknown")
    content = Map.get(msg, :content, "")
    line_count = content |> String.split("\n") |> length()

    summary =
      content
      |> String.split("\n")
      |> List.first("")
      |> String.slice(0, 100)

    %{msg | content: "[Superseded] #{name}: #{line_count} lines. First line: #{summary}"}
  end

  defp squash_tool_result(msg), do: msg

  # ── Step 2-3: Detail Level Decay ───────────────────────────────

  defp apply_detail_decay(messages, total, stats, file_index, memory_index) do
    # Don't compress system/first-user messages (indices 0, 1)
    # Don't compress the most recent 25% of messages
    protected_tail = max(2, div(total, 4))

    compressible_range = 2..(total - protected_tail - 1)//1

    if Range.size(compressible_range) <= 0 do
      {messages, stats}
    else
      {compressed, compression_count} =
        messages
        |> Enum.with_index()
        |> Enum.map_reduce(0, fn {msg, idx}, acc ->
          if idx in compressible_range do
            detail = detail_level(idx, total)

            {compressed_msg, did_compress} =
              compress_by_detail(msg, detail, file_index, memory_index)

            {compressed_msg, acc + if(did_compress, do: 1, else: 0)}
          else
            {msg, acc}
          end
        end)

      {compressed, %{stats | compressions: stats.compressions + compression_count}}
    end
  end

  @doc false
  def detail_level(index, total) when total > 0 do
    1.0 - index / max(total, 1)
  end

  def detail_level(_index, _total), do: 1.0

  defp compress_by_detail(msg, detail, _file_index, _memory_index) when detail >= 0.8 do
    # Full fidelity
    {msg, false}
  end

  defp compress_by_detail(%{role: :tool} = msg, detail, file_index, memory_index)
       when detail >= 0.5 do
    # Omission with pointer — keep tool name + summary, suggest re-read
    content = Map.get(msg, :content, "")
    name = Map.get(msg, :name, "tool")

    if String.length(content) > 200 do
      line_count = content |> String.split("\n") |> length()
      first_line = content |> String.split("\n") |> List.first("") |> String.slice(0, 120)

      stub =
        "#{name}: #{line_count} lines. Summary: #{first_line}... " <>
          "(detail_level=#{Float.round(detail, 2)}, use tool to re-read if needed)"

      new_content = enrich_stub(stub, name, file_index, memory_index, content)
      {%{msg | content: new_content}, true}
    else
      {msg, false}
    end
  end

  defp compress_by_detail(%{role: :tool} = msg, detail, file_index, memory_index)
       when detail >= 0.2 do
    # Heuristic one-liner
    name = Map.get(msg, :name, "tool")
    content = Map.get(msg, :content, "")

    success = not String.starts_with?(content, "ERROR")
    status = if success, do: "ok", else: "FAILED"

    first_line =
      content
      |> String.split("\n")
      |> List.first("")
      |> String.slice(0, 80)

    stub = "[#{status}] #{name}: #{first_line}"
    new_content = enrich_stub(stub, name, file_index, memory_index, content)
    {%{msg | content: new_content}, true}
  end

  defp compress_by_detail(%{role: :tool} = msg, _detail, file_index, memory_index) do
    # Very old — minimal stub, but still enriched with index metadata
    name = Map.get(msg, :name, "tool")
    content = Map.get(msg, :content, "")
    success = not String.starts_with?(content, "ERROR")
    status = if success, do: "ok", else: "FAILED"
    stub = "[#{status}] #{name}"
    new_content = enrich_stub(stub, name, file_index, memory_index, content)
    {%{msg | content: new_content}, true}
  end

  defp compress_by_detail(%{role: :assistant} = msg, detail, _file_index, _memory_index)
       when detail < 0.5 do
    # Compress long assistant messages
    content = Map.get(msg, :content, "")

    if is_binary(content) and String.length(content) > 300 do
      truncated =
        String.slice(content, 0, 200) <> "... (truncated, detail=#{Float.round(detail, 2)})"

      {%{msg | content: truncated}, true}
    else
      {msg, false}
    end
  end

  defp compress_by_detail(msg, _detail, _file_index, _memory_index), do: {msg, false}

  # ── Step 4: LLM Narrative Summary ─────────────────────────────

  defp apply_llm_narrative(messages, total, config, stats) do
    # Find messages with detail_level < 0.2 that could be batched
    candidates =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {_msg, idx} ->
        idx >= 2 and detail_level(idx, total) < 0.2
      end)

    if length(candidates) >= 4 do
      # Batch these into a narrative summary
      batch_msgs = Enum.map(candidates, fn {msg, _idx} -> msg end)
      batch_indices = Enum.map(candidates, fn {_msg, idx} -> idx end) |> MapSet.new()

      case generate_narrative(batch_msgs, config) do
        {:ok, narrative} ->
          # Replace batch with single narrative message
          summary_msg = %{
            role: :assistant,
            content: "[Context Summary] #{narrative}"
          }

          remaining =
            messages
            |> Enum.with_index()
            |> Enum.reject(fn {_msg, idx} -> idx in batch_indices end)
            |> Enum.map(fn {msg, _idx} -> msg end)

          # Insert narrative after system+user messages
          {before, after_msgs} = Enum.split(remaining, 2)
          result = before ++ [summary_msg] ++ after_msgs

          {result, %{stats | narratives: stats.narratives + 1}}

        {:error, _reason} ->
          {messages, stats}
      end
    else
      {messages, stats}
    end
  end

  defp generate_narrative(messages, config) do
    prompt = build_narrative_prompt(messages)

    ai_mod = Module.concat([:Arbor, :AI])

    if Code.ensure_loaded?(ai_mod) and function_exported?(ai_mod, :generate_text, 2) do
      case apply(ai_mod, :generate_text, [
             prompt,
             [
               model: config.compaction_model,
               provider: config.compaction_provider,
               max_tokens: 500,
               temperature: 0.2,
               backend: :api
             ]
           ]) do
        {:ok, response} ->
          text = extract_response_text(response)
          if text && String.length(text) > 0, do: {:ok, text}, else: {:error, :empty_response}

        error ->
          error
      end
    else
      {:error, :ai_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp build_narrative_prompt(messages) do
    formatted =
      Enum.map_join(messages, "\n", fn msg ->
        role = Map.get(msg, :role, :unknown)
        content = Map.get(msg, :content, "") |> String.slice(0, 300)
        name = Map.get(msg, :name)

        if name do
          "  [#{role}:#{name}] #{content}"
        else
          "  [#{role}] #{content}"
        end
      end)

    """
    Summarize these agent actions into a concise narrative paragraph (2-3 sentences).
    Preserve: what was attempted, what succeeded, what failed, and key findings.
    Failed attempts are especially important — note what didn't work and why.

    Messages:
    #{formatted}

    Write only the summary paragraph, nothing else.
    """
  end

  defp extract_response_text(%{message: %{content: content}}) when is_binary(content), do: content

  defp extract_response_text(%{message: %{content: parts}}) when is_list(parts) do
    parts
    |> Enum.filter(fn p -> Map.get(p, :type) in [:text, "text"] end)
    |> Enum.map_join("", fn p -> Map.get(p, :text, "") end)
  end

  defp extract_response_text(%{text: text}) when is_binary(text), do: text
  defp extract_response_text(_), do: nil

  # ── File Index ─────────────────────────────────────────────────

  defp maybe_update_file_index(compactor, %{role: :tool, name: name, content: content} = _msg)
       when is_binary(name) and is_binary(content) do
    cond do
      name in @file_read_tools ->
        update_file_index_for_read(compactor, content)

      name in @file_write_tools ->
        # Invalidate the hash — file was modified
        case extract_path_from_content(content) do
          nil -> compactor
          path -> invalidate_file_index(compactor, path)
        end

      true ->
        compactor
    end
  end

  defp maybe_update_file_index(compactor, _msg), do: compactor

  defp update_file_index_for_read(compactor, content) do
    case extract_path_from_content(content) do
      nil ->
        compactor

      path ->
        # Extract actual file content from JSON wrapper if present
        file_content = extract_file_body(content)

        hash = content_hash(file_content)
        line_count = file_content |> String.split("\n") |> length()

        summary =
          file_content
          |> String.split("\n")
          |> Enum.reject(&(String.trim(&1) == ""))
          |> List.first("")
          |> String.slice(0, 100)

        modules = extract_module_names(file_content)
        key_functions = extract_key_functions(file_content)

        entry = %{
          content_hash: hash,
          last_seen_turn: compactor.turn,
          line_count: line_count,
          summary: summary,
          modules: modules,
          key_functions: key_functions
        }

        %{compactor | file_index: Map.put(compactor.file_index, path, entry)}
    end
  end

  # Extract the actual file content from various result formats
  defp extract_file_body(content) when is_binary(content) do
    if String.starts_with?(content, "{") do
      case Jason.decode(content) do
        {:ok, %{"content" => body}} when is_binary(body) -> body
        _ -> content
      end
    else
      content
    end
  end

  defp invalidate_file_index(compactor, path) do
    %{compactor | file_index: Map.delete(compactor.file_index, path)}
  end

  defp maybe_deduplicate_file_read(compactor, %{role: :tool, name: name, content: content} = msg)
       when is_binary(name) and is_binary(content) do
    if name in @file_read_tools do
      case extract_path_from_content(content) do
        nil -> msg
        path -> check_file_dedup(compactor, msg, path, content)
      end
    else
      msg
    end
  end

  defp maybe_deduplicate_file_read(_compactor, msg), do: msg

  defp check_file_dedup(compactor, msg, path, content) do
    case Map.get(compactor.file_index, path) do
      %{content_hash: prev_hash, last_seen_turn: seen_turn, line_count: lines} ->
        if content_hash(extract_file_body(content)) == prev_hash do
          %{
            msg
            | content:
                "Content unchanged since turn #{seen_turn} " <>
                  "(#{lines} lines, file: #{path}). Use file_read to see content again."
          }
        else
          msg
        end

      nil ->
        msg
    end
  end

  # ── Content Extraction ────────────────────────────────────────

  defp extract_module_names(content) when is_binary(content) do
    Regex.scan(~r/defmodule\s+([\w.]+)/, content)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  defp extract_module_names(_), do: []

  defp extract_key_functions(content) when is_binary(content) do
    # Only public functions (def, not defp) — limit to first 8
    Regex.scan(~r/^\s*def\s+(\w+)/m, content, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp extract_key_functions(_), do: []

  # Route enrichment to file index or memory index based on tool name
  defp enrich_stub(stub, name, file_index, memory_index, content) do
    if name in @memory_read_tools or name in @memory_write_tools do
      enrich_with_memory_index(stub, memory_index, content)
    else
      enrich_with_file_index(stub, file_index, content)
    end
  end

  # Enrich a compressed stub with file index metadata
  defp enrich_with_file_index(stub, file_index, content) do
    case extract_path_from_content(content) do
      nil ->
        stub

      path ->
        case Map.get(file_index, path) do
          %{modules: modules, key_functions: fns} when modules != [] ->
            mod_info = "Modules: #{Enum.join(modules, ", ")}"

            fn_info =
              if fns != [], do: ". Key functions: #{Enum.join(fns, ", ")}", else: ""

            "#{stub} [#{mod_info}#{fn_info}]"

          _ ->
            stub
        end
    end
  end

  # Enrich a compressed stub with memory index metadata
  defp enrich_with_memory_index(stub, memory_index, content) do
    # Find the best matching memory index entry for this content
    key = extract_memory_key(content)

    case key && Map.get(memory_index, key) do
      %{} = entry ->
        parts = []

        parts =
          if entry.person_names != [],
            do: parts ++ ["People: #{Enum.join(entry.person_names, ", ")}"],
            else: parts

        parts =
          if entry.relationship_dynamics != [],
            do: parts ++ ["Dynamic: #{Enum.join(entry.relationship_dynamics, ", ")}"],
            else: parts

        parts =
          if entry.emotional_markers != [],
            do: parts ++ ["Emotions: #{Enum.join(entry.emotional_markers, ", ")}"],
            else: parts

        parts =
          if entry.values != [],
            do: parts ++ ["Values: #{Enum.join(Enum.take(entry.values, 5), ", ")}"],
            else: parts

        parts =
          if entry.self_knowledge_categories != %{} do
            cats =
              Enum.map_join(entry.self_knowledge_categories, ", ", fn {cat, count} ->
                "#{cat} (#{count})"
              end)

            parts ++ ["Self-knowledge: #{cats}"]
          else
            parts
          end

        parts =
          if entry.query, do: parts ++ ["Query: \"#{entry.query}\""], else: parts

        if parts != [] do
          "#{stub} [#{Enum.join(parts, ". ")}]"
        else
          stub
        end

      _ ->
        stub
    end
  end

  # ── Memory Index ──────────────────────────────────────────────

  defp maybe_update_memory_index(compactor, %{role: :tool, name: name, content: content})
       when is_binary(name) and is_binary(content) do
    if name in @memory_read_tools or name in @memory_write_tools do
      update_memory_index_entry(compactor, name, content)
    else
      compactor
    end
  end

  defp maybe_update_memory_index(compactor, _msg), do: compactor

  defp update_memory_index_entry(compactor, name, content) do
    key = extract_memory_key(content) || "turn_#{compactor.turn}_#{name}"

    person_names = extract_person_names(content)
    emotional_markers = extract_emotional_markers(content)
    dynamics = extract_relationship_dynamics(content)
    values = extract_values_from_content(content)
    sk_categories = extract_self_knowledge_categories(content)
    query = extract_memory_query(name, content)

    entry = %{
      content_hash: content_hash(content),
      last_seen_turn: compactor.turn,
      person_names: person_names,
      emotional_markers: emotional_markers,
      relationship_dynamics: dynamics,
      values: values,
      self_knowledge_categories: sk_categories,
      query: query
    }

    %{compactor | memory_index: Map.put(compactor.memory_index, key, entry)}
  end

  defp find_memory_read_indices(messages, _memory_index) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn {msg, idx} ->
      name = to_string(Map.get(msg, :name, ""))
      content = Map.get(msg, :content, "")

      if msg.role == :tool and is_binary(content) and name in @memory_read_tools do
        maybe_memory_index_entry(content, idx)
      else
        []
      end
    end)
  end

  defp maybe_memory_index_entry(content, idx) do
    case extract_memory_key(content) do
      nil -> []
      key -> [{idx, "memory:#{key}"}]
    end
  end

  # Extract a key for memory index lookups — person name or query string
  defp extract_memory_key(content) when is_binary(content) do
    cond do
      # JSON format with name field (relationship tools)
      match = Regex.run(~r/"name"\s*:\s*"([^"]+)"/, content) ->
        "person:#{Enum.at(match, 1)}"

      # Person name from text patterns
      match = Regex.run(~r/(?:Relationship|Person|Name):\s*(\w[\w\s]*)/i, content) ->
        "person:#{String.trim(Enum.at(match, 1))}"

      # Query from recall results
      match = Regex.run(~r/"query"\s*:\s*"([^"]+)"/, content) ->
        "query:#{Enum.at(match, 1)}"

      # Self-knowledge / identity
      String.contains?(content, "self_knowledge") or String.contains?(content, "identity") ->
        "self"

      true ->
        nil
    end
  end

  defp extract_memory_key(_), do: nil

  # ── Memory Metadata Extraction ──────────────────────────────

  defp extract_person_names(content) when is_binary(content) do
    names =
      Regex.scan(~r/"name"\s*:\s*"([^"]+)"/, content)
      |> Enum.map(fn [_, name] -> name end)

    # Also match "Primary Collaborator: Name" or "Person: Name" patterns
    text_names =
      Regex.scan(
        ~r/(?:Collaborator|Person|Partner|Friend|User):\s*(\w[\w\s]*?)(?:\.|,|\n|$)/i,
        content
      )
      |> Enum.map(fn [_, name] -> String.trim(name) end)

    (names ++ text_names) |> Enum.uniq()
  end

  defp extract_person_names(_), do: []

  @known_emotional_markers ~w(
    trust joy insight connection gratitude warmth concern hope curiosity
    vulnerability frustration pride wonder compassion empathy satisfaction
    excitement nervousness sadness relief amusement surprise contentment
    meaningful philosophical collaborative supportive creative
  )

  defp extract_emotional_markers(content) when is_binary(content) do
    content_lower = String.downcase(content)

    @known_emotional_markers
    |> Enum.filter(&String.contains?(content_lower, &1))
  end

  defp extract_emotional_markers(_), do: []

  defp extract_relationship_dynamics(content) when is_binary(content) do
    dynamics =
      Regex.scan(~r/"relationship_dynamic"\s*:\s*"([^"]+)"/, content)
      |> Enum.map(fn [_, d] -> d end)

    text_dynamics =
      Regex.scan(~r/(?:Relationship|Dynamic):\s*(.+?)(?:\n|$)/i, content)
      |> Enum.map(fn [_, d] -> String.trim(d) end)
      |> Enum.reject(&(String.length(&1) > 100))

    (dynamics ++ text_dynamics) |> Enum.uniq()
  end

  defp extract_relationship_dynamics(_), do: []

  defp extract_values_from_content(content) when is_binary(content) do
    # JSON array: "values": ["a", "b"]
    json_values =
      case Regex.run(~r/"values"\s*:\s*\[([^\]]+)\]/, content) do
        [_, list_str] ->
          Regex.scan(~r/"([^"]+)"/, list_str)
          |> Enum.map(fn [_, v] -> v end)

        _ ->
          []
      end

    # Text pattern: "Values: honesty, empathy, ..."
    text_values =
      case Regex.run(~r/Values?:\s*(.+?)(?:\n|$)/i, content) do
        [_, vals] ->
          vals |> String.split(~r/[,;]/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        _ ->
          []
      end

    (json_values ++ text_values) |> Enum.uniq() |> Enum.take(10)
  end

  defp extract_values_from_content(_), do: []

  @self_knowledge_categories ~w(capability trait value preference personality)

  defp extract_self_knowledge_categories(content) when is_binary(content) do
    content_lower = String.downcase(content)

    @self_knowledge_categories
    |> Enum.reduce(%{}, fn category, acc ->
      count =
        Regex.scan(~r/#{category}/i, content_lower)
        |> length()

      if count > 0, do: Map.put(acc, category, count), else: acc
    end)
  end

  defp extract_self_knowledge_categories(_), do: %{}

  defp extract_memory_query(name, content) do
    if name in ~w(memory_recall) do
      case Regex.run(~r/"query"\s*:\s*"([^"]+)"/, content) do
        [_, query] -> query
        _ -> nil
      end
    else
      nil
    end
  end

  # ── Token Estimation ───────────────────────────────────────────

  defp estimate_tokens(message) when is_map(message) do
    content = Map.get(message, :content, "")

    text =
      cond do
        is_binary(content) -> content
        is_list(content) -> inspect(content)
        true -> ""
      end

    # Add overhead for tool calls in assistant messages
    tool_calls = Map.get(message, :tool_calls, [])
    tool_overhead = length(tool_calls) * 50

    max(1, div(String.length(text), @chars_per_token) + tool_overhead)
  end

  defp estimate_tokens(_), do: 1

  defp count_all_tokens(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_tokens(msg) end)
  end

  defp model_context_size(model) do
    # Runtime bridge to TokenBudget
    token_budget = Module.concat([:Arbor, :Memory, :TokenBudget])

    if Code.ensure_loaded?(token_budget) and
         function_exported?(token_budget, :model_context_size, 1) do
      apply(token_budget, :model_context_size, [model])
    else
      # Reasonable defaults for common models
      cond do
        String.contains?(model, "claude") -> 200_000
        String.contains?(model, "gpt-4o") -> 128_000
        String.contains?(model, "gemini") -> 1_000_000
        true -> 100_000
      end
    end
  end

  defp content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp token_roi(reasoning_tokens, 0), do: if(reasoning_tokens > 0, do: 1.0, else: 0.0)

  defp token_roi(reasoning_tokens, compression_count) do
    # Rough estimate: each compression saves ~100 tokens of overhead
    management_overhead = compression_count * 5
    total = reasoning_tokens + management_overhead
    if total > 0, do: Float.round(reasoning_tokens / total, 3), else: 1.0
  end
end
