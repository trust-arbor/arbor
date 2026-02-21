defmodule Arbor.Orchestrator.UnifiedLLM.LocalModelsLiveTest do
  @moduledoc """
  Live integration tests exercising local LLM providers:
  - LM Studio (qwen/qwen3-coder-next) for code generation
  - Ollama (nomic-embed-text) for semantic embeddings

  These tests hit real local inference servers and are excluded by default.
  Run with: mix test --only llm_local
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{LMStudio, Ollama}
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request}

  @moduletag :llm_local
  @moduletag timeout: 120_000

  # -- Config --

  @coder_model "qwen/qwen3-coder-next"
  @embed_model "nomic-embed-text:latest"
  @ollama_embed_url "http://localhost:11434/v1/embeddings"

  # -- Setup --

  setup_all do
    lm_studio_up = LMStudio.available?()
    ollama_up = Ollama.available?()

    unless lm_studio_up and ollama_up do
      IO.puts("""
      \n[SKIP] Local model tests require both servers:
        LM Studio (#{if lm_studio_up, do: "OK", else: "DOWN"}) — needs #{@coder_model}
        Ollama    (#{if ollama_up, do: "OK", else: "DOWN"}) — needs #{@embed_model}
      """)
    end

    %{lm_studio: lm_studio_up, ollama: ollama_up}
  end

  # ── Embeddings Helper ──

  defp embed(texts) when is_list(texts) do
    case Req.post(@ollama_embed_url,
           json: %{"model" => @embed_model, "input" => texts},
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, Enum.map(data, & &1["embedding"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed(text) when is_binary(text) do
    case embed([text]) do
      {:ok, [vec]} -> {:ok, vec}
      error -> error
    end
  end

  defp cosine_similarity(a, b) when is_list(a) and is_list(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  # ── Code Generation Helper ──

  defp ask_coder(prompt, opts \\ []) do
    system =
      Keyword.get(
        opts,
        :system,
        "You are an expert Elixir developer. Respond only with code, no explanations unless asked."
      )

    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    temperature = Keyword.get(opts, :temperature, 0.2)

    request = %Request{
      model: @coder_model,
      messages: [
        Message.new(:system, system),
        Message.new(:user, prompt)
      ],
      max_tokens: max_tokens,
      temperature: temperature
    }

    case LMStudio.complete(request, []) do
      {:ok, response} -> {:ok, response.text}
      error -> error
    end
  end

  defp extract_code(text) do
    case Regex.run(~r/```elixir\n(.*?)```/s, text) do
      [_, code] ->
        String.trim(code)

      nil ->
        case Regex.run(~r/```\n(.*?)```/s, text) do
          [_, code] -> String.trim(code)
          nil -> String.trim(text)
        end
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Test 1: Elixir GenServer Challenge
  # Same challenge given to other models — write a key-value store
  # ══════════════════════════════════════════════════════════════════

  describe "GenServer coding challenge" do
    @tag :llm_local
    test "writes a working key-value store GenServer", %{lm_studio: lm} do
      unless lm, do: flunk("LM Studio not available")

      prompt = """
      Write an Elixir GenServer module called `KVStore` that implements a simple
      key-value store with these features:

      1. `start_link/1` accepting an optional initial map
      2. `put(pid, key, value)` — stores a key-value pair
      3. `get(pid, key)` — retrieves a value (returns nil if missing)
      4. `delete(pid, key)` — removes a key
      5. `keys(pid)` — returns all keys as a list
      6. `size(pid)` — returns the number of entries

      Use proper GenServer callbacks (init, handle_call, handle_cast).
      Make `put` and `delete` asynchronous (cast), everything else synchronous (call).
      Include a @moduledoc and typespecs for the public API.
      """

      {:ok, raw} = ask_coder(prompt, max_tokens: 4096)
      code = extract_code(raw)

      # Structural checks
      assert code =~ "defmodule",
             "Generated code must contain a module definition"

      assert code =~ "use GenServer" or code =~ "@behaviour GenServer" or
               code =~ "GenServer.start_link(__MODULE__",
             "Must use GenServer (via use, @behaviour, or start_link(__MODULE__))"

      assert code =~ "def start_link",
             "Must implement start_link"

      assert code =~ "handle_call",
             "Must implement handle_call callbacks"

      assert code =~ "handle_cast",
             "Must implement handle_cast callbacks"

      assert code =~ ~r/def (put|get|delete|keys|size)/,
             "Must implement at least some public API functions"

      # If the model forgot `use GenServer` but uses @impl true + __MODULE__,
      # inject it so we can test the logic (common LLM omission)
      code =
        if not (code =~ "use GenServer") and code =~ "GenServer.start_link(__MODULE__" do
          String.replace(code, "defmodule KVStore do", "defmodule KVStore do\n  use GenServer",
            global: false
          )
        else
          code
        end

      # Verify it actually compiles
      compile_result =
        try do
          # Live test: compiling LLM-generated code to verify correctness
          # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
          Code.compile_string(code)
          :ok
        rescue
          e -> {:error, Exception.message(e)}
        end

      assert compile_result == :ok,
             "Generated code must compile. Got error: #{inspect(compile_result)}"

      # Try to exercise the generated module
      exercise_result =
        try do
          # Live test: compiling and exercising LLM-generated GenServer
          # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
          [{mod, _}] = Code.compile_string(code)

          # The model might expect keyword opts or a plain map — try both
          {:ok, pid} =
            case mod.start_link([]) do
              {:ok, pid} -> {:ok, pid}
              _ -> mod.start_link(%{})
            end

          mod.put(pid, :hello, "world")
          # cast is async, give it a moment
          Process.sleep(50)

          val = mod.get(pid, :hello)
          assert val == "world", "get(:hello) should return \"world\", got: #{inspect(val)}"

          k = mod.keys(pid)
          assert :hello in k or "hello" in k, "keys() should include :hello"

          s = mod.size(pid)
          assert s == 1, "size() should be 1, got: #{s}"

          mod.delete(pid, :hello)
          Process.sleep(50)

          assert mod.get(pid, :hello) == nil, "get(:hello) after delete should be nil"
          assert mod.size(pid) == 0, "size() after delete should be 0"

          GenServer.stop(pid)
          :ok
        rescue
          e -> {:error, Exception.message(e)}
        after
          # Clean up compiled module
          :code.purge(KVStore)
          :code.delete(KVStore)
        end

      assert exercise_result == :ok,
             "Generated GenServer must work correctly: #{inspect(exercise_result)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Test 2: Bug Finding Challenge
  # ══════════════════════════════════════════════════════════════════

  describe "bug finding challenge" do
    @tag :llm_local
    test "identifies and fixes a subtle Elixir bug", %{lm_studio: lm} do
      unless lm, do: flunk("LM Studio not available")

      buggy_code = """
      defmodule RateLimiter do
        use GenServer

        def start_link(opts) do
          max_requests = Keyword.get(opts, :max_requests, 10)
          window_ms = Keyword.get(opts, :window_ms, 60_000)
          GenServer.start_link(__MODULE__, {max_requests, window_ms})
        end

        def allow?(pid), do: GenServer.call(pid, :check)

        @impl true
        def init({max_requests, window_ms}) do
          {:ok, %{max: max_requests, window: window_ms, requests: []}}
        end

        @impl true
        def handle_call(:check, _from, state) do
          now = System.monotonic_time(:millisecond)
          cutoff = now - state.window

          # BUG: This filter keeps requests OUTSIDE the window instead of inside
          recent = Enum.filter(state.requests, fn ts -> ts < cutoff end)

          if length(recent) < state.max do
            {:reply, true, %{state | requests: [now | recent]}}
          else
            {:reply, false, %{state | requests: recent}}
          end
        end
      end
      """

      prompt = """
      This Elixir GenServer has a subtle bug in the `handle_call(:check, ...)` function.
      The RateLimiter is supposed to allow up to `max_requests` within a sliding time window,
      but it has the opposite behavior — it keeps old requests instead of recent ones.

      Here's the code:

      ```elixir
      #{buggy_code}
      ```

      1. Identify the bug precisely (which line and what's wrong)
      2. Show the corrected version of JUST the `handle_call` function
      3. Explain why the original is wrong in one sentence
      """

      {:ok, response} =
        ask_coder(prompt,
          system: "You are an expert Elixir developer and code reviewer. Be precise and concise.",
          max_tokens: 2048
        )

      # The fix should mention the comparison operator needs to flip
      response_lower = String.downcase(response)

      assert response_lower =~ ">" or response_lower =~ "greater" or
               response_lower =~ ">=" or response_lower =~ "after" or
               response_lower =~ "inside" or response_lower =~ "within",
             "Should identify the comparison direction bug"

      assert response =~ "cutoff" or response =~ "filter" or response =~ "recent",
             "Should reference the filtering logic"

      # The corrected code should have >= or > cutoff
      assert response =~ ~r/ts\s*>=?\s*cutoff/ or response =~ ~r/>\s*cutoff/ or
               response =~ ~r/>=\s*cutoff/,
             "Corrected code should flip the comparison to ts >= cutoff"
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Test 3: Embeddings — Semantic Code Understanding
  # ══════════════════════════════════════════════════════════════════

  describe "semantic embeddings" do
    @tag :llm_local
    test "nomic-embed-text produces meaningful code embeddings", %{ollama: ol} do
      unless ol, do: flunk("Ollama not available")

      # Embed code snippets and concept descriptions, verify semantic proximity
      snippets = [
        # GenServer pattern
        """
        defmodule Counter do
          use GenServer
          def init(count), do: {:ok, count}
          def handle_call(:get, _from, count), do: {:reply, count, count}
          def handle_cast(:inc, count), do: {:noreply, count + 1}
        end
        """,
        # Supervisor pattern
        """
        defmodule MyApp.Supervisor do
          use Supervisor
          def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg)
          def init(_init_arg) do
            children = [{MyWorker, []}]
            Supervisor.init(children, strategy: :one_for_one)
          end
        end
        """,
        # Pure functional — completely different
        """
        defmodule MathUtils do
          def fibonacci(0), do: 0
          def fibonacci(1), do: 1
          def fibonacci(n) when n > 1, do: fibonacci(n-1) + fibonacci(n-2)
          def factorial(0), do: 1
          def factorial(n) when n > 0, do: n * factorial(n-1)
        end
        """
      ]

      concepts = [
        "OTP GenServer process with state management and message passing",
        "Supervisor tree for fault tolerance and process lifecycle",
        "Recursive mathematical functions without side effects"
      ]

      {:ok, code_vecs} = embed(snippets)
      {:ok, concept_vecs} = embed(concepts)

      assert length(code_vecs) == 3
      assert length(concept_vecs) == 3

      # Build similarity matrix
      matrix =
        for i <- 0..2 do
          for j <- 0..2 do
            cosine_similarity(Enum.at(code_vecs, i), Enum.at(concept_vecs, j))
          end
        end

      # The diagonal (matching pairs) should have higher average than off-diagonal
      diagonal = Enum.with_index(matrix) |> Enum.map(fn {row, i} -> Enum.at(row, i) end)

      off_diag =
        for {row, i} <- Enum.with_index(matrix), {val, j} <- Enum.with_index(row), i != j, do: val

      avg_diag = Enum.sum(diagonal) / 3
      avg_off = Enum.sum(off_diag) / 6

      assert avg_diag > avg_off,
             "Diagonal avg (#{Float.round(avg_diag, 4)}) should exceed " <>
               "off-diagonal avg (#{Float.round(avg_off, 4)}). " <>
               "Matrix: #{inspect(Enum.map(matrix, fn row -> Enum.map(row, &Float.round(&1, 4)) end))}"

      # GenServer code (snippet 0) should be most similar to OTP concept (0),
      # NOT to the pure math concept (2)
      assert Enum.at(Enum.at(matrix, 0), 0) > Enum.at(Enum.at(matrix, 0), 2),
             "GenServer code should be closer to OTP concept than to math concept"

      # Math code (snippet 2) should be most similar to math concept (2)
      assert Enum.at(Enum.at(matrix, 2), 2) > Enum.at(Enum.at(matrix, 2), 0),
             "Math code should be closer to math concept than to OTP concept"
    end

    @tag :llm_local
    test "embeddings cluster related Elixir concepts", %{ollama: ol} do
      unless ol, do: flunk("Ollama not available")

      # Three clusters: OTP, testing, data processing
      texts = [
        # OTP cluster
        "GenServer handle_call handle_cast init state management",
        "Supervisor one_for_one restart strategy child spec",
        # Testing cluster
        "ExUnit assert describe test setup mock",
        "property-based testing StreamData generators shrinking",
        # Data processing cluster
        "Enum.map Enum.filter Enum.reduce Stream.chunk",
        "Flow partitions MapReduce parallel data pipeline"
      ]

      {:ok, vecs} = embed(texts)
      assert length(vecs) == 6

      # Within-cluster similarity should exceed cross-cluster similarity
      otp_sim = cosine_similarity(Enum.at(vecs, 0), Enum.at(vecs, 1))
      test_sim = cosine_similarity(Enum.at(vecs, 2), Enum.at(vecs, 3))
      data_sim = cosine_similarity(Enum.at(vecs, 4), Enum.at(vecs, 5))

      # Cross-cluster: OTP vs Testing
      cross_1 = cosine_similarity(Enum.at(vecs, 0), Enum.at(vecs, 2))
      # Cross-cluster: Testing vs Data
      cross_2 = cosine_similarity(Enum.at(vecs, 2), Enum.at(vecs, 4))
      # Cross-cluster: OTP vs Data
      cross_3 = cosine_similarity(Enum.at(vecs, 0), Enum.at(vecs, 4))

      avg_within = (otp_sim + test_sim + data_sim) / 3.0
      avg_cross = (cross_1 + cross_2 + cross_3) / 3.0

      assert avg_within > avg_cross,
             "Within-cluster avg (#{Float.round(avg_within, 4)}) should exceed " <>
               "cross-cluster avg (#{Float.round(avg_cross, 4)}). " <>
               "OTP=#{Float.round(otp_sim, 4)}, Test=#{Float.round(test_sim, 4)}, " <>
               "Data=#{Float.round(data_sim, 4)} vs " <>
               "Cross: #{Float.round(cross_1, 4)}, #{Float.round(cross_2, 4)}, #{Float.round(cross_3, 4)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Test 4: Combined — Code Gen + Semantic Verification
  # Write code, then verify it covers expected concepts via embeddings
  # ══════════════════════════════════════════════════════════════════

  describe "code generation with semantic verification" do
    @tag :llm_local
    test "generated code is semantically close to its specification", ctx do
      unless ctx.lm_studio and ctx.ollama do
        flunk("Both LM Studio and Ollama required")
      end

      spec = """
      Write an Elixir module called `TaskQueue` that implements a simple
      priority task queue using an Agent. It should support:
      - `start_link/0` to start the agent with an empty queue
      - `push(pid, task, priority)` where priority is :high, :normal, or :low
      - `pop(pid)` returns the highest priority task (high > normal > low), or nil
      - `size(pid)` returns total number of tasks
      - `drain(pid)` returns all tasks in priority order and empties the queue
      """

      {:ok, raw} = ask_coder(spec, max_tokens: 3072)
      code = extract_code(raw)

      # Basic structural check
      assert code =~ "defmodule"
      assert code =~ "Agent"

      # Semantic verification: embed the spec and the generated code,
      # verify they're highly similar (code should match its spec)
      {:ok, [spec_vec, code_vec]} = embed([spec, code])
      similarity = cosine_similarity(spec_vec, code_vec)

      assert similarity > 0.3,
             "Generated code should be semantically similar to spec. " <>
               "Cosine similarity: #{Float.round(similarity, 4)}"

      # Also verify it's closer to "Elixir Agent priority queue" than to
      # something unrelated like "JavaScript React component"
      {:ok, [related_vec, unrelated_vec]} =
        embed([
          "Elixir Agent process priority queue with push pop drain operations",
          "JavaScript React useState useEffect component rendering virtual DOM"
        ])

      sim_related = cosine_similarity(code_vec, related_vec)
      sim_unrelated = cosine_similarity(code_vec, unrelated_vec)

      assert sim_related > sim_unrelated,
             "Code should be closer to 'Elixir Agent queue' (#{Float.round(sim_related, 4)}) " <>
               "than to 'React component' (#{Float.round(sim_unrelated, 4)})"
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Test 5: Pattern Completion — Elixir Idioms
  # ══════════════════════════════════════════════════════════════════

  describe "Elixir pattern completion" do
    @tag :llm_local
    test "completes an Elixir pipeline correctly", %{lm_studio: lm} do
      unless lm, do: flunk("LM Studio not available")

      prompt = """
      Complete this Elixir function. Return ONLY the completed function, nothing else.

      ```elixir
      def top_words(text, n \\\\ 10) do
        text
        |> String.downcase()
        |> String.split(~r/[^\\w]+/, trim: true)
        |> # YOUR CODE: count word frequencies, sort by count desc, take top n
      end
      ```
      """

      {:ok, raw} = ask_coder(prompt, max_tokens: 1024)
      code = extract_code(raw)

      # Should use Enum functions for frequency counting
      assert code =~ "Enum" or code =~ "frequencies" or code =~ "reduce",
             "Should use Enum operations for word counting"

      assert code =~ "sort" or code =~ "Enum.sort",
             "Should sort results"

      assert code =~ "take" or code =~ "slice" or code =~ "Enum.take",
             "Should take top N results"
    end

    @tag :llm_local
    test "writes a proper with statement", %{lm_studio: lm} do
      unless lm, do: flunk("LM Studio not available")

      prompt = """
      Write an Elixir function `create_user(params)` that uses a `with` statement to:
      1. Validate the email format (must contain @)
      2. Validate the password length (minimum 8 characters)
      3. Hash the password (just use `:crypto.hash(:sha256, password) |> Base.encode16()`)
      4. Return {:ok, user_map} with name, email, and hashed_password

      Each validation step should return `{:error, reason}` on failure.
      Return ONLY the function definition.
      """

      {:ok, raw} = ask_coder(prompt, max_tokens: 1024)
      code = extract_code(raw)

      assert code =~ "with",
             "Should use a with statement"

      assert code =~ "@" or code =~ "email",
             "Should validate email"

      assert code =~ "8" or code =~ "length" or code =~ "byte_size",
             "Should check password length"

      assert code =~ "crypto" or code =~ "hash" or code =~ "sha256",
             "Should hash the password"

      assert code =~ "{:ok," or code =~ "{:error,",
             "Should use ok/error tuples"
    end
  end
end
