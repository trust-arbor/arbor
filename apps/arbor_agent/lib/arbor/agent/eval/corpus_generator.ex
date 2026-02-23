defmodule Arbor.Agent.Eval.CorpusGenerator do
  @moduledoc """
  Generates a padding corpus for the effective window eval.

  Two strategies:

  1. **Session sampling** (recommended) — Extracts real conversation messages from
     Claude Code session JSONL files. Free, instant, genuinely realistic.

  2. **LLM generation** — Uses gpt-5-nano via OpenRouter to generate synthetic
     conversation padding. Costs ~$0.80 for 2M tokens.

  The output is a JSONL file with one message per line, each having `role` and
  `content` fields. Both strategies append to the same file.

  ## Usage

      # Sample from session files (recommended):
      CorpusGenerator.sample_sessions(target_tokens: 2_000_000)

      # Or via Mix task:
      mix arbor.eval.generate_corpus --source sessions --target-tokens 2000000

      # LLM generation (slower, costs money):
      mix arbor.eval.generate_corpus --source llm --target-tokens 100000
  """

  require Logger

  @topics ~w(authentication payments caching search notifications
             deployment testing database migrations websockets
             rate_limiting file_uploads background_jobs logging
             pagination error_handling configuration monitoring
             api_design security performance profiling refactoring
             code_review ci_cd containerization load_balancing
             data_validation schema_design session_management)

  @message_types [:user, :assistant, :tool_file, :tool_test, :tool_search]

  @default_model "openai/gpt-5-nano"
  @default_provider "openrouter"
  @default_target_tokens 2_000_000
  @default_concurrency 10
  @max_tokens_per_call 4000

  @session_dir Path.expand("~/.claude/projects/-Users-azmaveth-code-trust-arbor-arbor")
  @min_content_length 50
  @max_content_length 10_000

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Sample conversation messages from Claude Code session JSONL files.

  Reads session transcripts, extracts user/assistant/tool messages, shuffles them,
  and appends to the corpus file until the target token count is reached.

  ## Options

    * `:target_tokens` - Target total tokens (default: 2,000,000)
    * `:output` - Output file path (default: priv/eval_data/padding_corpus.jsonl)
    * `:session_dir` - Directory containing session JSONL files
    * `:max_files` - Max session files to read (default: 10, biggest first)
    * `:shuffle_seed` - Seed for deterministic shuffling (default: 42)
  """
  @spec sample_sessions(keyword()) :: {:ok, map()} | {:error, term()}
  def sample_sessions(opts \\ []) do
    target_tokens = Keyword.get(opts, :target_tokens, @default_target_tokens)
    session_dir = Keyword.get(opts, :session_dir, @session_dir)
    max_files = Keyword.get(opts, :max_files, 10)
    shuffle_seed = Keyword.get(opts, :shuffle_seed, 42)

    default_output =
      Path.join(to_string(:code.priv_dir(:arbor_agent)), "eval_data/padding_corpus.jsonl")

    output_path = Keyword.get(opts, :output, default_output)

    # Ensure output directory
    output_path |> Path.dirname() |> File.mkdir_p!()

    existing_tokens = count_existing_tokens(output_path)

    if existing_tokens >= target_tokens do
      Logger.info("[CorpusGenerator] Corpus already has ~#{existing_tokens} tokens, skipping")

      {:ok,
       %{
         total_messages: count_existing_lines(output_path),
         total_tokens: existing_tokens,
         file_size_bytes: File.stat!(output_path).size,
         duration_ms: 0,
         output_path: output_path,
         source: :sessions
       }}
    else
      remaining_tokens = target_tokens - existing_tokens

      Logger.info(
        "[CorpusGenerator] Existing ~#{existing_tokens} tokens, " <>
          "sampling ~#{remaining_tokens} more from sessions"
      )

      do_sample_sessions(
        session_dir,
        output_path,
        remaining_tokens,
        existing_tokens,
        max_files,
        shuffle_seed
      )
    end
  end

  @doc """
  Generate a padding corpus via LLM API calls and write it to a JSONL file.

  ## Options

    * `:model` - LLM model ID (default: "openai/gpt-5-nano")
    * `:provider` - LLM provider (default: "openrouter")
    * `:target_tokens` - Target total tokens (default: 2,000,000)
    * `:concurrency` - Max concurrent API requests (default: 10)
    * `:output` - Output file path (default: priv/eval_data/padding_corpus.jsonl)
    * `:progress_fn` - Optional callback `fn(completed, total, tokens_so_far) -> :ok end`
  """
  @spec generate(keyword()) :: {:ok, map()} | {:error, term()}
  def generate(opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    provider = Keyword.get(opts, :provider, @default_provider)
    target_tokens = Keyword.get(opts, :target_tokens, @default_target_tokens)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    default_output =
      Path.join(to_string(:code.priv_dir(:arbor_agent)), "eval_data/padding_corpus.jsonl")

    output_path = Keyword.get(opts, :output, default_output)
    progress_fn = Keyword.get(opts, :progress_fn)

    # Ensure output directory exists
    output_path |> Path.dirname() |> File.mkdir_p!()

    # Check existing token count so we can skip if already at target
    existing_tokens = count_existing_tokens(output_path)

    if existing_tokens >= target_tokens do
      Logger.info("[CorpusGenerator] Corpus already has ~#{existing_tokens} tokens, skipping")

      {:ok,
       %{
         total_messages: count_existing_lines(output_path),
         total_tokens: existing_tokens,
         file_size_bytes: File.stat!(output_path).size,
         duration_ms: 0,
         output_path: output_path,
         model: model,
         provider: provider
       }}
    else
      remaining_tokens = target_tokens - existing_tokens
      num_calls = ceil(remaining_tokens / @max_tokens_per_call)
      batches = build_batches(num_calls)

      Logger.info(
        "[CorpusGenerator] Existing ~#{existing_tokens} tokens, " <>
          "generating ~#{remaining_tokens} more (#{num_calls} calls)"
      )

      do_generate(
        output_path,
        batches,
        num_calls,
        provider,
        model,
        concurrency,
        target_tokens,
        existing_tokens,
        progress_fn
      )
    end
  end

  defp do_generate(
         output_path,
         batches,
         num_calls,
         provider,
         model,
         concurrency,
         _target_tokens,
         existing_tokens,
         progress_fn
       ) do
    # Append to existing file
    file = File.open!(output_path, [:append, :utf8])
    start_time = System.monotonic_time(:millisecond)

    try do
      {total_messages, total_tokens} =
        batches
        |> Task.async_stream(
          fn {idx, topic, msg_type} ->
            generate_single(provider, model, topic, msg_type, idx)
          end,
          max_concurrency: concurrency,
          timeout: 120_000,
          on_timeout: :kill_task
        )
        |> Enum.reduce({0, 0, 0}, fn result, {completed, msg_count, token_count} ->
          completed = completed + 1

          case result do
            {:ok, {:ok, messages}} ->
              new_tokens =
                Enum.reduce(messages, 0, fn msg, acc ->
                  line = Jason.encode!(msg)
                  IO.write(file, line <> "\n")
                  acc + estimate_tokens(msg["content"] || "")
                end)

              if progress_fn do
                progress_fn.(completed, num_calls, token_count + new_tokens)
              end

              {completed, msg_count + length(messages), token_count + new_tokens}

            {:ok, {:error, reason}} ->
              Logger.warning("[CorpusGenerator] Call #{completed} failed: #{inspect(reason)}")

              if progress_fn do
                progress_fn.(completed, num_calls, token_count)
              end

              {completed, msg_count, token_count}

            {:exit, reason} ->
              Logger.warning("[CorpusGenerator] Call #{completed} timed out: #{inspect(reason)}")

              if progress_fn do
                progress_fn.(completed, num_calls, token_count)
              end

              {completed, msg_count, token_count}
          end
        end)
        |> then(fn {_completed, msg_count, token_count} -> {msg_count, token_count} end)

      elapsed = System.monotonic_time(:millisecond) - start_time
      file_size = File.stat!(output_path).size

      grand_total_tokens = existing_tokens + total_tokens
      grand_total_messages = count_existing_lines(output_path)

      stats = %{
        total_messages: grand_total_messages,
        total_tokens: grand_total_tokens,
        new_messages: total_messages,
        new_tokens: total_tokens,
        file_size_bytes: file_size,
        duration_ms: elapsed,
        output_path: output_path,
        model: model,
        provider: provider
      }

      Logger.info(
        "[CorpusGenerator] Complete: +#{total_messages} messages (#{grand_total_messages} total), " <>
          "~#{grand_total_tokens} tokens, #{format_bytes(file_size)}, #{elapsed}ms"
      )

      {:ok, stats}
    after
      File.close(file)
    end
  end

  # ── Session Sampling ──────────────────────────────────────────

  defp do_sample_sessions(
         session_dir,
         output_path,
         remaining_tokens,
         existing_tokens,
         max_files,
         shuffle_seed
       ) do
    start_time = System.monotonic_time(:millisecond)

    # Find session JSONL files, sorted by size (biggest first for most content)
    session_files =
      session_dir
      |> Path.join("*.jsonl")
      |> Path.wildcard()
      |> Enum.map(fn path -> {path, File.stat!(path).size} end)
      |> Enum.sort_by(fn {_path, size} -> size end, :desc)
      |> Enum.take(max_files)

    Logger.info(
      "[CorpusGenerator] Found #{length(session_files)} session files " <>
        "(#{format_bytes(Enum.reduce(session_files, 0, fn {_, s}, acc -> acc + s end))} total)"
    )

    if session_files == [] do
      {:error, :no_session_files}
    else
      # Extract messages from all files
      messages =
        session_files
        |> Enum.flat_map(fn {path, _size} ->
          Logger.debug("[CorpusGenerator] Reading #{Path.basename(path)}")
          extract_session_messages(path)
        end)

      Logger.info("[CorpusGenerator] Extracted #{length(messages)} messages from sessions")

      # Deterministic shuffle
      :rand.seed(:exsss, {shuffle_seed, shuffle_seed * 2, shuffle_seed * 3})
      shuffled = Enum.shuffle(messages)

      # Write messages until we hit the target
      file = File.open!(output_path, [:append, :utf8])

      try do
        {new_messages, new_tokens} =
          Enum.reduce_while(shuffled, {0, 0}, fn msg, {msg_count, token_count} ->
            if token_count >= remaining_tokens do
              {:halt, {msg_count, token_count}}
            else
              line = Jason.encode!(msg)
              IO.write(file, line <> "\n")
              tokens = estimate_tokens(msg["content"] || "")
              {:cont, {msg_count + 1, token_count + tokens}}
            end
          end)

        elapsed = System.monotonic_time(:millisecond) - start_time
        file_size = File.stat!(output_path).size
        grand_total_tokens = existing_tokens + new_tokens
        grand_total_messages = count_existing_lines(output_path)

        Logger.info(
          "[CorpusGenerator] Sampled +#{new_messages} messages (#{grand_total_messages} total), " <>
            "~#{grand_total_tokens} tokens, #{format_bytes(file_size)}, #{elapsed}ms"
        )

        {:ok,
         %{
           total_messages: grand_total_messages,
           total_tokens: grand_total_tokens,
           new_messages: new_messages,
           new_tokens: new_tokens,
           file_size_bytes: file_size,
           duration_ms: elapsed,
           output_path: output_path,
           source: :sessions
         }}
      after
        File.close(file)
      end
    end
  end

  defp extract_session_messages(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, record} -> extract_message(record)
        _ -> []
      end
    end)
  end

  defp extract_message(%{"type" => "user", "message" => %{"content" => content}})
       when is_binary(content) do
    if usable_content?(content) do
      [%{"role" => "user", "content" => truncate(content)}]
    else
      []
    end
  end

  defp extract_message(%{"type" => "user", "message" => %{"content" => parts}})
       when is_list(parts) do
    # Tool results come as arrays in user messages
    parts
    |> Enum.flat_map(fn
      %{"type" => "tool_result", "content" => content} when is_binary(content) ->
        if usable_content?(content),
          do: [%{"role" => "tool", "content" => truncate(content)}],
          else: []

      _ ->
        []
    end)
  end

  defp extract_message(%{"type" => "assistant", "message" => %{"content" => parts}})
       when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        if usable_content?(text),
          do: [%{"role" => "assistant", "content" => truncate(text)}],
          else: []

      _ ->
        []
    end)
  end

  defp extract_message(_), do: []

  defp usable_content?(content) do
    len = String.length(content)
    len >= @min_content_length and len <= @max_content_length
  end

  defp truncate(content) do
    if String.length(content) > @max_content_length do
      String.slice(content, 0, @max_content_length)
    else
      content
    end
  end

  # ── Batch Building ──────────────────────────────────────────────

  defp build_batches(num_calls) do
    topic_count = length(@topics)
    type_count = length(@message_types)

    Enum.map(0..(num_calls - 1), fn idx ->
      # Interleave types first, then cycle topics — ensures variety even with few calls
      msg_type = Enum.at(@message_types, rem(idx, type_count))
      topic = Enum.at(@topics, rem(div(idx, type_count), topic_count))
      {idx, topic, msg_type}
    end)
  end

  # ── Single Generation ──────────────────────────────────────────

  defp generate_single(provider, model, topic, msg_type, idx) do
    prompt = build_prompt(msg_type, topic)

    case call_llm(provider, model, prompt) do
      {:ok, text} ->
        messages = parse_response(msg_type, text)

        Logger.debug(
          "[CorpusGenerator] Call #{idx} (#{msg_type}/#{topic}): " <>
            "#{String.length(text)} chars → #{length(messages)} messages"
        )

        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Prompt Building ──────────────────────────────────────────

  defp build_prompt(:user, topic) do
    """
    Write 10 unique developer messages asking a coding assistant about #{format_topic(topic)} in an Elixir/Phoenix project.
    Each message should be 1-3 sentences, realistic, and specific.
    Number them 1 through 10, one per line.
    Do NOT include any preamble or explanation — just the numbered messages.
    """
  end

  defp build_prompt(:assistant, topic) do
    """
    Write 5 unique coding assistant responses about #{format_topic(topic)} in an Elixir/Phoenix project.
    Each response should be 3-8 sentences with technical detail, code references, and actionable recommendations.
    Separate each response with a line containing only "---".
    Do NOT include any preamble or explanation — just the responses separated by ---.
    """
  end

  defp build_prompt(:tool_file, topic) do
    """
    Write 3 realistic Elixir source file contents related to #{format_topic(topic)}.
    Each file should be 20-50 lines of valid Elixir code with module, functions, and documentation.
    Start each file with a comment line like: # File: lib/my_app/some_module.ex
    Separate files with a line containing only "---".
    Do NOT include any preamble or explanation.
    """
  end

  defp build_prompt(:tool_test, topic) do
    """
    Write 3 realistic ExUnit test output results for tests about #{format_topic(topic)}.
    Include test names, timing, pass/fail counts, and realistic assertion details.
    Separate each result with a line containing only "---".
    Do NOT include any preamble or explanation.
    """
  end

  defp build_prompt(:tool_search, topic) do
    """
    Write 3 realistic code search results (like ripgrep output) for queries about #{format_topic(topic)} in an Elixir project.
    Include file paths, line numbers, and matching code snippets.
    Separate each result block with a line containing only "---".
    Do NOT include any preamble or explanation.
    """
  end

  # ── Response Parsing ──────────────────────────────────────────

  defp parse_response(:user, text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      Regex.match?(~r/^\d+[\.\)]\s+/, line)
    end)
    |> Enum.map(fn line ->
      # Strip the number prefix
      content = Regex.replace(~r/^\d+[\.\)]\s*/, line, "")
      %{"role" => "user", "content" => content}
    end)
    |> Enum.reject(fn msg -> String.length(msg["content"]) < 10 end)
  end

  defp parse_response(:assistant, text) do
    text
    |> String.split(~r/\n---\n|\n---$|^---\n/m)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn section ->
      %{"role" => "assistant", "content" => section}
    end)
    |> Enum.reject(fn msg -> String.length(msg["content"]) < 20 end)
  end

  defp parse_response(tool_type, text) when tool_type in [:tool_file, :tool_test, :tool_search] do
    prefix = tool_type_prefix(tool_type)

    text
    |> String.split(~r/\n---\n|\n---$|^---\n/m)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn section ->
      %{"role" => "tool", "content" => "[#{prefix}]\n#{section}"}
    end)
    |> Enum.reject(fn msg -> String.length(msg["content"]) < 20 end)
  end

  defp tool_type_prefix(:tool_file), do: "File Read"
  defp tool_type_prefix(:tool_test), do: "Test Results"
  defp tool_type_prefix(:tool_search), do: "Code Search"

  # ── LLM Call ──────────────────────────────────────────────────

  defp call_llm(provider, model, prompt) do
    client_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Client])
    request_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Request])
    message_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Message])

    if Code.ensure_loaded?(client_mod) and Code.ensure_loaded?(request_mod) and
         Code.ensure_loaded?(message_mod) do
      messages = [
        struct(message_mod, %{
          role: :system,
          content:
            "You are a content generator for evaluation datasets. " <>
              "Follow the formatting instructions precisely."
        }),
        struct(message_mod, %{role: :user, content: prompt})
      ]

      request =
        struct(request_mod, %{
          provider: provider,
          model: model,
          messages: messages,
          max_tokens: @max_tokens_per_call,
          temperature: 1.0
        })

      client = apply(client_mod, :from_env, [[]])

      case apply(client_mod, :complete, [client, request, [timeout: 90_000]]) do
        {:ok, response} ->
          text = Map.get(response, :text) || Map.get(response, :content) || ""

          {:ok, text}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unified_llm_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp format_topic(topic) do
    topic
    |> String.replace("_", " ")
    |> String.replace("ci cd", "CI/CD")
    |> String.replace("api design", "API design")
  end

  defp estimate_tokens(text) when is_binary(text) do
    max(1, div(String.length(text), 4))
  end

  defp estimate_tokens(_), do: 1

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)}MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)}KB"
  end

  defp format_bytes(bytes), do: "#{bytes}B"

  defp count_existing_tokens(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce(0, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"content" => content}} when is_binary(content) ->
            acc + estimate_tokens(content)

          _ ->
            acc
        end
      end)
    else
      0
    end
  end

  defp count_existing_lines(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Enum.count(&(&1 != ""))
    else
      0
    end
  end
end
