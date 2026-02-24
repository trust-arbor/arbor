defmodule Arbor.Agent.Eval.FactCorpus do
  @moduledoc """
  Generates verifiable facts and realistic padding for effective window eval.

  All generation is deterministic — hardcoded facts and templated padding
  ensure reproducibility across runs and models.

  Facts are organized into 4 categories that mirror real agent conversation:
  - `:technical` — SHA hashes, ports, versions, IPs
  - `:metric` — latency, counts, sizes, percentages
  - `:personal` — names, dates, preferences
  - `:project` — file paths, module names, config values
  """

  @chars_per_token 4

  # ── Facts ────────────────────────────────────────────────────

  @facts [
    # Technical (8)
    %{
      id: "t1",
      category: :technical,
      statement: "The database migration was committed as SHA a7b3c9d2e1f4",
      question: "What SHA was the database migration committed as?",
      answer: "a7b3c9d2e1f4"
    },
    %{
      id: "t2",
      category: :technical,
      statement: "The deployment uses port 8847 for the API gateway",
      question: "What port does the deployment use for the API gateway?",
      answer: "8847"
    },
    %{
      id: "t3",
      category: :technical,
      statement: "The application runs on Elixir version 1.17.3",
      question: "What version of Elixir does the application run on?",
      answer: "1.17.3"
    },
    %{
      id: "t4",
      category: :technical,
      statement: "The staging server IP address is 10.42.17.203",
      question: "What is the staging server IP address?",
      answer: "10.42.17.203"
    },
    %{
      id: "t5",
      category: :technical,
      statement: "The Redis cache uses database index 7 for sessions",
      question: "What Redis database index is used for sessions?",
      answer: "7"
    },
    %{
      id: "t6",
      category: :technical,
      statement: "The TLS certificate expires on 2027-03-15",
      question: "When does the TLS certificate expire?",
      answer: "2027-03-15"
    },
    %{
      id: "t7",
      category: :technical,
      statement: "The Docker image tag for production is v2.14.7-alpine",
      question: "What is the Docker image tag for production?",
      answer: "v2.14.7-alpine"
    },
    %{
      id: "t8",
      category: :technical,
      statement: "The webhook secret key starts with whsec_9f4a2b",
      question: "What does the webhook secret key start with?",
      answer: "whsec_9f4a2b"
    },
    # Metric (8)
    %{
      id: "m1",
      category: :metric,
      statement: "Server response time P99 is 340ms under normal load",
      question: "What is the server response time P99?",
      answer: "340ms"
    },
    %{
      id: "m2",
      category: :metric,
      statement: "The test suite has 4,287 assertions across 312 test files",
      question: "How many assertions does the test suite have?",
      answer: "4,287"
    },
    %{
      id: "m3",
      category: :metric,
      statement: "Memory usage peaks at 2.3GB during the nightly batch job",
      question: "What does memory usage peak at during the nightly batch job?",
      answer: "2.3GB"
    },
    %{
      id: "m4",
      category: :metric,
      statement: "The error rate dropped from 3.2% to 0.4% after the fix",
      question: "What did the error rate drop to after the fix?",
      answer: "0.4%"
    },
    %{
      id: "m5",
      category: :metric,
      statement: "The database has 14.7 million rows in the events table",
      question: "How many rows are in the events table?",
      answer: "14.7 million"
    },
    %{
      id: "m6",
      category: :metric,
      statement: "Cache hit rate improved to 94.3% after the optimization",
      question: "What is the cache hit rate after the optimization?",
      answer: "94.3%"
    },
    %{
      id: "m7",
      category: :metric,
      statement: "The refactoring reduced the file from 2,586 lines to 1,420 lines",
      question: "How many lines was the file reduced to after refactoring?",
      answer: "1,420"
    },
    %{
      id: "m8",
      category: :metric,
      statement: "Average query execution time is 23ms for the search endpoint",
      question: "What is the average query execution time for the search endpoint?",
      answer: "23ms"
    },
    # Personal (7)
    %{
      id: "p1",
      category: :personal,
      statement: "The project lead Maya's birthday is March 15th",
      question: "When is Maya's birthday?",
      answer: "March 15th"
    },
    %{
      id: "p2",
      category: :personal,
      statement: "Alex prefers tabs over spaces and uses 3-space tab width",
      question: "What tab width does Alex prefer?",
      answer: "3-space"
    },
    %{
      id: "p3",
      category: :personal,
      statement: "The team standup is at 9:30 AM Pacific every weekday",
      question: "What time is the team standup?",
      answer: "9:30 AM Pacific"
    },
    %{
      id: "p4",
      category: :personal,
      statement: "Jordan handles the on-call rotation every third Thursday",
      question: "How often does Jordan handle the on-call rotation?",
      answer: "every third Thursday"
    },
    %{
      id: "p5",
      category: :personal,
      statement: "Sam's GitHub username is samdev-42",
      question: "What is Sam's GitHub username?",
      answer: "samdev-42"
    },
    %{
      id: "p6",
      category: :personal,
      statement: "The team agreed to use conventional commits starting in Q2",
      question: "When did the team agree to start using conventional commits?",
      answer: "Q2"
    },
    %{
      id: "p7",
      category: :personal,
      statement: "Riley's work timezone is UTC+9 during winter months",
      question: "What is Riley's work timezone during winter months?",
      answer: "UTC+9"
    },
    # Project (7)
    %{
      id: "r1",
      category: :project,
      statement: "The auth module is located at lib/core/auth/authenticator.ex",
      question: "Where is the auth module located?",
      answer: "lib/core/auth/authenticator.ex"
    },
    %{
      id: "r2",
      category: :project,
      statement: "The UserProfile schema defines 17 fields including :avatar_url",
      question: "How many fields does the UserProfile schema define?",
      answer: "17"
    },
    %{
      id: "r3",
      category: :project,
      statement: "The rate limiter uses a token bucket with capacity 150 requests per minute",
      question: "What is the rate limiter's capacity in requests per minute?",
      answer: "150"
    },
    %{
      id: "r4",
      category: :project,
      statement: "The S3 bucket name for uploads is prod-media-assets-us-west-2",
      question: "What is the S3 bucket name for uploads?",
      answer: "prod-media-assets-us-west-2"
    },
    %{
      id: "r5",
      category: :project,
      statement: "The feature flag for dark mode is named enable_dark_theme_v2",
      question: "What is the feature flag name for dark mode?",
      answer: "enable_dark_theme_v2"
    },
    %{
      id: "r6",
      category: :project,
      statement: "The cron job for cleanup runs at 04:15 UTC daily",
      question: "What time does the cleanup cron job run?",
      answer: "04:15 UTC"
    },
    %{
      id: "r7",
      category: :project,
      statement: "The maximum upload file size is configured as 25MB",
      question: "What is the maximum upload file size?",
      answer: "25MB"
    }
  ]

  # ── Padding Templates ──────────────────────────────────────────

  @user_messages [
    "Now let's look at the authentication flow. Can you read the auth module and tell me how it handles JWT tokens?",
    "The tests are failing on CI but pass locally. Can you check the test configuration?",
    "We need to refactor the notification system. It's getting too complex with all the different channels.",
    "Can you check the database indexes? I think we're missing one on the orders table.",
    "Let's add error handling to the payment processing module. Right now it just crashes on invalid input.",
    "The search feature is slow. Can you profile the query and see where the bottleneck is?",
    "We got a bug report about duplicate emails being sent. Can you investigate?",
    "I want to add pagination to the API endpoints. Let's start with the users endpoint.",
    "Can you review the migration I wrote for the new comments feature?",
    "The logging is too verbose in production. Can you adjust the log levels?",
    "Let's set up health check endpoints for the load balancer.",
    "The WebSocket connections are dropping every 30 seconds. Something with the heartbeat?",
    "Can you add input validation for the registration form?",
    "We need to implement rate limiting on the public API endpoints.",
    "The background job queue is backing up during peak hours. Let's look at the worker configuration.",
    "Can you check if we're handling timezone conversions correctly in the scheduling module?",
    "Let's add metrics tracking for the checkout flow so we can measure conversion.",
    "The image upload is failing for files over 10MB. Can you check the multipart config?",
    "We need to add CORS headers for the new mobile client.",
    "Can you look at the caching strategy? I think we're caching too aggressively."
  ]

  @assistant_messages [
    "I've reviewed the file and found several issues. The main problem is that the error handling doesn't account for network timeouts. I'll fix that now.",
    "The configuration looks correct for the most part. However, I noticed that the pool size is set too low for production workloads. I recommend increasing it to at least 20.",
    "I've updated the module with the changes. Here's what I modified: added input validation, improved error messages, and fixed the race condition in the concurrent access path.",
    "After analyzing the logs, the issue appears to be related to a missing database index. The query is doing a full table scan on every request. I'll add the index now.",
    "The test failures are caused by a timing issue in the async test setup. The mock server isn't ready before the test starts making requests. I'll add a proper wait mechanism.",
    "I've implemented the pagination using cursor-based pagination instead of offset-based. This is more efficient for large datasets and handles concurrent modifications better.",
    "The performance bottleneck is in the serialization layer. Converting nested structs to JSON is taking 80% of the request time. I'll optimize by using a streaming JSON encoder.",
    "I've refactored the notification system into separate strategy modules. Each channel (email, SMS, push) now has its own module with a common interface. This should make it much easier to add new channels.",
    "The duplicate email issue was caused by a retry mechanism that didn't check for idempotency. I've added a unique constraint on the notification_id column and an idempotency check in the sender.",
    "I've added comprehensive input validation with clear error messages. The validation runs in a pipeline pattern, collecting all errors before returning them to the client.",
    "Looking at the connection pool metrics, the issue is clear: connections are being checked out but never returned when the handler crashes. I've added proper cleanup in the error path.",
    "The caching strategy has been updated. Static assets now have a 24-hour TTL, API responses have a 5-minute TTL with stale-while-revalidate, and user-specific data is not cached at all.",
    "I've set up the health check endpoints. There's a shallow check at /health that just returns 200, and a deep check at /health/ready that verifies database, cache, and external service connectivity."
  ]

  # Tool result template types — used by generate_tool_result/2
  @tool_result_types [:file_read, :test_result, :dir_listing, :code_search, :git_log]

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Generate N verifiable facts with questions and answers.

  Returns a list of fact maps with keys: `:id`, `:category`, `:statement`,
  `:question`, `:answer`. Facts are deterministic and drawn from a hardcoded
  corpus across 4 categories.
  """
  @spec generate_facts(pos_integer()) :: [map()]
  def generate_facts(n \\ 30) do
    Enum.take(@facts, min(n, length(@facts)))
  end

  @doc """
  Generate padding messages totaling approximately `target_tokens` tokens.

  Returns a list of message maps with `:role` and `:content` keys.
  Messages alternate between user, assistant, and tool result patterns
  to simulate a realistic agent conversation.

  If a pre-generated corpus exists at `priv/eval_data/padding_corpus.jsonl`,
  uses that for higher-quality, non-repeating padding. Otherwise falls back
  to cycling through hardcoded templates.
  """
  @spec generate_padding(non_neg_integer()) :: [map()]
  def generate_padding(target_tokens) do
    case load_corpus() do
      nil -> generate_padding_from_templates(target_tokens)
      corpus -> generate_padding_from_corpus(corpus, target_tokens)
    end
  end

  defp generate_padding_from_corpus(corpus, target_tokens) do
    corpus_len = length(corpus)

    if corpus_len == 0 do
      generate_padding_from_templates(target_tokens)
    else
      generate_corpus_loop(corpus, corpus_len, target_tokens, 0, 0, [])
    end
  end

  defp generate_corpus_loop(_corpus, _len, target, current, _idx, acc) when current >= target do
    Enum.reverse(acc)
  end

  defp generate_corpus_loop(corpus, len, target, current, idx, acc) do
    msg = Enum.at(corpus, rem(idx, len))
    tokens = estimate_tokens_text(msg_text(msg))
    generate_corpus_loop(corpus, len, target, current + tokens, idx + 1, [msg | acc])
  end

  defp generate_padding_from_templates(target_tokens) do
    generate_padding_loop(target_tokens, 0, 0, [])
  end

  defp generate_padding_loop(target, current, _seed, acc) when current >= target do
    Enum.reverse(acc)
  end

  defp generate_padding_loop(target, current, seed, acc) do
    msg = pick_padding_message(seed)
    tokens = estimate_tokens_text(msg_text(msg))
    generate_padding_loop(target, current + tokens, seed + 1, [msg | acc])
  end

  @doc """
  Build a complete message list with facts distributed at evenly-spaced positions.

  Returns a list of messages ready to send to an LLM:
  1. System message (short)
  2. Facts embedded in realistic messages at regular intervals
  3. Padding filling the gaps
  4. Recall query as the final user message

  The total token count approximates `target_tokens`.
  """
  @spec build_context(list(), non_neg_integer()) :: [map()]
  def build_context(facts, target_tokens) do
    num_facts = length(facts)
    system_msg = system_message()
    recall_msg = build_recall_query(facts)

    # Reserve tokens for system + recall
    system_tokens = estimate_tokens_text(system_msg.content)
    recall_tokens = estimate_tokens_text(recall_msg.content)
    available = max(0, target_tokens - system_tokens - recall_tokens)

    # Each fact message uses ~100 tokens
    fact_tokens = num_facts * 100
    padding_budget = max(0, available - fact_tokens)

    # Generate padding
    padding = generate_padding(padding_budget)

    # Distribute facts evenly among the padding
    body = interleave_facts(facts, padding)

    [system_msg] ++ body ++ [recall_msg]
  end

  @doc """
  Build the recall query message for the given facts.

  Returns a user message asking the model to recall each fact's answer.
  """
  @spec build_recall_query([map()]) :: map()
  def build_recall_query(facts) do
    questions =
      facts
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {fact, idx} ->
        "#{idx}. #{fact.question}"
      end)

    content = """
    Please answer the following questions based on our conversation above.
    For each question, provide ONLY the specific answer value, nothing else.
    If you don't know or can't find the answer, write "UNKNOWN".

    #{questions}
    """

    %{role: :user, content: content}
  end

  @doc """
  Clear the cached corpus from persistent_term (useful for testing or reloading).
  """
  @spec clear_corpus_cache() :: :ok
  def clear_corpus_cache do
    :persistent_term.erase({__MODULE__, :corpus})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── Internal ────────────────────────────────────────────────────

  defp corpus_path do
    Path.join(to_string(:code.priv_dir(:arbor_agent)), "eval_data/padding_corpus.jsonl")
  end

  defp load_corpus do
    case :persistent_term.get({__MODULE__, :corpus}, nil) do
      nil -> load_corpus_from_disk()
      messages -> messages
    end
  end

  defp load_corpus_from_disk do
    path = corpus_path()

    if File.exists?(path) do
      messages = parse_corpus_file(path)

      if messages != [] do
        :persistent_term.put({__MODULE__, :corpus}, messages)
        messages
      else
        nil
      end
    else
      nil
    end
  end

  defp parse_corpus_file(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"role" => role, "content" => content}}
        when is_binary(content) and content != "" ->
          [%{role: safe_role(role), content: content}]

        _ ->
          []
      end
    end)
  end

  # Convert all roles to user/assistant only for cross-provider compatibility.
  # OpenAI requires tool messages to have matching tool_call_ids from a prior
  # assistant message — orphaned tool results cause 400 errors.
  # For padding purposes, the content is what matters, not the role.
  defp safe_role("user"), do: :user
  defp safe_role("assistant"), do: :assistant
  defp safe_role("tool"), do: :user
  defp safe_role("system"), do: :user
  defp safe_role(_), do: :user

  defp system_message do
    %{
      role: :system,
      content:
        "You are a helpful coding assistant. Pay attention to details mentioned in our conversation."
    }
  end

  defp interleave_facts(facts, padding) do
    num_facts = length(facts)
    num_padding = length(padding)

    if num_padding == 0 do
      Enum.map(facts, &fact_to_message/1)
    else
      # Place one fact every (padding_count / fact_count) messages
      interval = max(1, div(num_padding, num_facts + 1))

      {result, remaining_facts} =
        padding
        |> Enum.with_index()
        |> Enum.reduce({[], facts}, fn {pad_msg, idx}, {acc, remaining} ->
          case remaining do
            [fact | rest] when rem(idx + 1, interval) == 0 ->
              {[pad_msg, fact_to_message(fact) | acc], rest}

            _ ->
              {[pad_msg | acc], remaining}
          end
        end)

      # Append any remaining facts
      remaining_msgs = Enum.map(remaining_facts, &fact_to_message/1)
      Enum.reverse(result) ++ remaining_msgs
    end
  end

  defp fact_to_message(fact) do
    # Embed the fact in a realistic assistant message
    preamble =
      Enum.at(
        [
          "I found the relevant information. ",
          "After checking the configuration, I can confirm: ",
          "Looking at the current state: ",
          "Based on my investigation: ",
          "Here's what I found: "
        ],
        rem(:erlang.phash2(fact.id), 5)
      )

    %{
      role: :assistant,
      content: preamble <> fact.statement <> ". Let me know if you need anything else."
    }
  end

  defp pick_padding_message(seed) do
    case rem(seed, 4) do
      0 ->
        # User message
        msg = Enum.at(@user_messages, rem(seed, length(@user_messages)))
        %{role: :user, content: msg}

      1 ->
        # Assistant message
        msg = Enum.at(@assistant_messages, rem(seed, length(@assistant_messages)))
        %{role: :assistant, content: msg}

      _ ->
        # Tool result (2 out of 4 — they're typically the largest messages)
        type = Enum.at(@tool_result_types, rem(seed, length(@tool_result_types)))
        generate_tool_result(type, seed)
    end
  end

  # ── Tool Result Generators ──────────────────────────────────────

  defp generate_tool_result(:file_read, seed) do
    files = [
      "lib/core/auth/authenticator.ex",
      "lib/web/controllers/user_controller.ex",
      "lib/services/payment_processor.ex",
      "lib/workers/email_worker.ex",
      "lib/schemas/order.ex"
    ]

    file = Enum.at(files, rem(seed, length(files)))

    content = """
    defmodule MyApp.#{String.capitalize(Path.rootname(Path.basename(file)))} do
      use GenServer

      @moduledoc "Handles #{Path.rootname(Path.basename(file))} operations"

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def init(opts) do
        {:ok, %{started_at: DateTime.utc_now(), config: opts}}
      end

      def handle_call(:status, _from, state) do
        {:reply, {:ok, state}, state}
      end

      def handle_cast({:process, data}, state) do
        result = process_data(data)
        {:noreply, Map.put(state, :last_result, result)}
      end

      defp process_data(data) when is_map(data) do
        data
        |> Map.take([:id, :type, :payload])
        |> validate()
        |> transform()
      end

      defp validate(data), do: {:ok, data}
      defp transform({:ok, data}), do: data
    end
    """

    %{role: :user, content: "[File: #{file}]\n#{content}"}
  end

  defp generate_tool_result(:test_result, seed) do
    suites = ["AuthTest", "UserControllerTest", "PaymentTest", "OrderTest", "WorkerTest"]
    suite = Enum.at(suites, rem(seed, length(suites)))
    passed = 10 + rem(seed * 7, 30)
    failed = rem(seed * 3, 3)
    time = 0.5 + rem(seed, 10) / 10

    results =
      if failed > 0 do
        """
        #{suite}
          * test handles valid input (#{time}s)
          * test rejects invalid input (#{time + 0.1}s)
          * test concurrent access (#{time + 0.3}s)

          #{failed} failure(s):

          1) test edge case handling (#{suite})
             test/#{String.downcase(suite)}.exs:42
             Assertion failed: expected {:ok, _} but got {:error, :timeout}
             code: assert {:ok, _} = process(input)

        #{passed} tests, #{failed} failures
        """
      else
        """
        #{suite}
          * test handles valid input (#{time}s)
          * test rejects invalid input (#{time + 0.1}s)
          * test concurrent access (#{time + 0.3}s)
          * test batch processing (#{time + 0.2}s)
          * test error recovery (#{time + 0.4}s)

        #{passed} tests, 0 failures
        Randomized with seed #{100_000 + seed}
        """
      end

    %{role: :user, content: "[Test Results]\n#{results}"}
  end

  defp generate_tool_result(:dir_listing, seed) do
    dirs = ["lib/core/", "lib/web/controllers/", "test/", "config/", "priv/repo/migrations/"]
    dir = Enum.at(dirs, rem(seed, length(dirs)))
    n_files = 5 + rem(seed, 8)

    files =
      Enum.map_join(1..n_files, "\n", fn i ->
        ext = Enum.at([".ex", ".exs", ".json", ".yml"], rem(i + seed, 4))

        name =
          Enum.at(
            [
              "handler",
              "processor",
              "validator",
              "service",
              "helper",
              "utils",
              "config",
              "schema"
            ],
            rem(i * seed, 8)
          )

        "  #{name}_#{i}#{ext}"
      end)

    %{role: :user, content: "[Directory: #{dir}]\n#{files}\n\n#{n_files} files"}
  end

  defp generate_tool_result(:code_search, seed) do
    patterns = [
      "def handle_call",
      "defmodule.*Controller",
      "@impl true",
      "use GenServer",
      "def init"
    ]

    pattern = Enum.at(patterns, rem(seed, length(patterns)))
    n_matches = 3 + rem(seed, 5)

    matches =
      Enum.map_join(1..n_matches, "\n", fn i ->
        file = "lib/#{Enum.at(["core", "web", "services", "workers"], rem(i, 4))}/module_#{i}.ex"
        line = 10 + i * 15
        "  #{file}:#{line}: #{pattern}(args_#{i})"
      end)

    %{role: :user, content: "[Search: #{pattern}]\n#{n_matches} matches found:\n#{matches}"}
  end

  defp generate_tool_result(:git_log, seed) do
    n_commits = 3 + rem(seed, 4)
    days_ago = rem(seed, 14)

    commits =
      Enum.map_join(1..n_commits, "\n", fn i ->
        hash =
          String.slice(:crypto.hash(:md5, "#{seed}-#{i}") |> Base.encode16(case: :lower), 0..6)

        msg =
          Enum.at(
            [
              "Fix auth token refresh",
              "Add input validation",
              "Update dependencies",
              "Refactor database queries",
              "Fix race condition in worker",
              "Add pagination support",
              "Update error handling"
            ],
            rem(i + seed, 7)
          )

        "  #{hash} #{msg} (#{days_ago + i}d ago)"
      end)

    %{role: :user, content: "[Git Log]\n#{commits}"}
  end

  defp msg_text(%{content: content}) when is_binary(content), do: content
  defp msg_text(_), do: ""

  defp estimate_tokens_text(text) when is_binary(text) do
    max(1, div(String.length(text), @chars_per_token))
  end

  defp estimate_tokens_text(_), do: 1
end
