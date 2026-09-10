defmodule Arbor.Memory.HybridRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Config.Reader

  @moduletag :fast
  @runtime_path Path.expand("../../../../../config/runtime.exs", __DIR__)
  @hybrid_keys ~w(ARBOR_HYBRID_MEMORY_ENABLED ARBOR_HYBRID_MEMORY_PROVIDER ARBOR_HYBRID_MEMORY_MODEL ARBOR_HYBRID_MEMORY_BASE_URL ARBOR_HYBRID_MEMORY_TIMEOUT_MS ARBOR_HYBRID_MEMORY_MIN_COSINE ARBOR_HYBRID_MEMORY_MIN_SCORE ARBOR_HYBRID_MEMORY_SEMANTIC_WEIGHT ARBOR_HYBRID_MEMORY_SELECTOR_PROVIDER ARBOR_HYBRID_MEMORY_SELECTOR_MODEL ARBOR_HYBRID_MEMORY_SELECTOR_BASE_URL ARBOR_HYBRID_MEMORY_SELECTOR_TIMEOUT_MS ARBOR_HYBRID_MEMORY_CANDIDATE_LIMIT)
  @private_keys ~w(ARBOR_PRIVATE_MEMORY_ENABLED ARBOR_PRIVATE_MEMORY_PROVIDER ARBOR_PRIVATE_MEMORY_MODEL ARBOR_PRIVATE_MEMORY_BASE_URL ARBOR_PRIVATE_MEMORY_TIMEOUT_MS)
  @env_keys @hybrid_keys ++
              @private_keys ++
              ~w(ARBOR_LM_STUDIO_BASE_URL ARBOR_HOME ARBOR_ENV_PATH ARBOR_VALIDATION_RUNTIME_CONFIG_PATH ARBOR_APPLE_CONTAINER_CONFIG_PATH ARBOR_OLLAMA_BASE_URL ARBOR_OLLAMA_CHAT_BASE_URL OLLAMA_API_KEY ARBOR_DB ARBOR_DB_NAME DB_USER DB_PASS ARBOR_DB_POOL_SIZE ARBOR_DATA_DIR ARBOR_SQLITE_PATH SECRET_KEY_BASE)
  @route_key :hybrid_knowledge_search
  @embedding_base "http://127.0.0.1:11434/v1"
  @selector_base "http://127.0.0.1:1234/v1"

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})

    app_previous =
      Enum.map(
        [{:arbor_orchestrator, :lm_studio}, {:arbor_llm, :trusted_proxy_endpoints}],
        fn {app, key} -> {app, key, Application.fetch_env(app, key)} end
      )

    Enum.each(@env_keys, &System.delete_env/1)

    root =
      Path.join(System.tmp_dir!(), "hybrid-runtime-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    System.put_env("ARBOR_HOME", root)
    System.put_env("ARBOR_ENV_PATH", Path.join(root, ".env"))

    on_exit(fn ->
      Enum.each(app_previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)

      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "unset opt-in preserves disabled default and existing programmatic configuration", %{
    root: root
  } do
    System.put_env("ARBOR_HYBRID_MEMORY_SELECTOR_PROVIDER", "ignored-without-opt-in")
    runtime = read_runtime(root)
    assert Keyword.fetch(runtime[:arbor_memory] || [], @route_key) == :error

    for existing <- [false, [enabled: true, model: "explicit-programmatic-route"]] do
      merged = Reader.merge([arbor_memory: [{@route_key, existing}]], runtime)
      assert merged[:arbor_memory][@route_key] == existing
    end
  end

  test "explicit false disables an existing route without validating companions", %{root: root} do
    for key <- @hybrid_keys, do: System.put_env(key, "ignored-while-disabled")
    System.put_env("ARBOR_HYBRID_MEMORY_ENABLED", "false")
    runtime = read_runtime(root)
    assert runtime[:arbor_memory][@route_key] === false
    merged = Reader.merge([arbor_memory: [{@route_key, [enabled: true]}]], runtime)
    assert merged[:arbor_memory][@route_key] === false
  end

  test "explicit opt-in projects the existing route shape with conservative defaults", %{
    root: root
  } do
    put_enabled()

    assert route(read_runtime(root)) == [
             enabled: true,
             provider: "ollama",
             model: "fixture-embedding-model",
             base_url: @embedding_base,
             timeout_ms: 10_000,
             min_cosine: 0.7,
             min_score: 0.6,
             semantic_weight: 0.7,
             selector: [
               provider: "lm_studio",
               model: "fixture-selector-model",
               base_url: @selector_base,
               timeout_ms: 20_000,
               candidate_limit: 8
             ]
           ]
  end

  test "LM Studio embedding and explicit numeric endpoints retain exact values", %{root: root} do
    for {timeout, selector_timeout, candidates, number} <- [
          {1, 1, 1, "0"},
          {30_000, 20_000, 8, "1"}
        ] do
      put_enabled()
      System.put_env("ARBOR_HYBRID_MEMORY_PROVIDER", "lm_studio")
      System.put_env("ARBOR_HYBRID_MEMORY_BASE_URL", @selector_base)
      System.put_env("ARBOR_HYBRID_MEMORY_TIMEOUT_MS", Integer.to_string(timeout))

      System.put_env(
        "ARBOR_HYBRID_MEMORY_SELECTOR_TIMEOUT_MS",
        Integer.to_string(selector_timeout)
      )

      System.put_env("ARBOR_HYBRID_MEMORY_CANDIDATE_LIMIT", Integer.to_string(candidates))
      for key <- unit_keys(), do: System.put_env(key, number)
      actual = route(read_runtime(root))
      assert actual[:provider] == "lm_studio" and actual[:base_url] == @selector_base
      assert actual[:timeout_ms] == timeout
      assert actual[:selector][:timeout_ms] == selector_timeout
      assert actual[:selector][:candidate_limit] == candidates
      assert actual[:min_cosine] == String.to_integer(number)
      assert actual[:min_score] == String.to_integer(number)
      assert actual[:semantic_weight] == String.to_integer(number)
    end
  end

  test "dev dotenv precedes the bridge and enables its explicit selector", %{root: root} do
    write_dotenv(root)
    actual = route(read_runtime(root))
    assert actual[:enabled] === true
    assert actual[:model] == "dotenv-embedding"
    assert actual[:selector][:model] == "dotenv-selector"
    assert actual[:selector][:candidate_limit] == 4
    assert actual[:min_cosine] == 0.7 and actual[:min_score] == 0.6
  end

  test "production reads the same explicit bridge with private fixture configuration only", %{
    root: root
  } do
    write_dotenv(root)
    # Config.Reader evaluates configuration only; it does not start Repo or make
    # provider calls. Satisfy unrelated production prerequisites with fixture data.
    adapter = Application.get_env(:arbor_persistence, :repo_adapter, Ecto.Adapters.SQLite3)

    backend =
      case adapter do
        Ecto.Adapters.SQLite3 -> "sqlite"
        Ecto.Adapters.Postgres -> "postgres"
      end

    System.put_env("ARBOR_DB", backend)
    System.put_env("ARBOR_DB_NAME", "synthetic_hybrid_config")
    System.put_env("DB_USER", "synthetic_hybrid_config")
    System.put_env("DB_PASS", "synthetic-config-only-not-a-credential")
    System.put_env("ARBOR_DATA_DIR", root)
    System.put_env("SECRET_KEY_BASE", String.duplicate("synthetic", 8))
    actual = route(read_runtime(root, :prod))
    assert actual[:enabled] === true and actual[:provider] == "ollama"
    assert actual[:selector][:provider] == "lm_studio"
    assert actual[:selector][:model] == "dotenv-selector"
  end

  test "test environment ignores dotenv activation and preserves fixture app config", %{
    root: root
  } do
    write_dotenv(root)
    runtime = read_runtime(root, :test)
    assert System.get_env("ARBOR_HYBRID_MEMORY_ENABLED") == "true"
    assert Keyword.fetch(runtime[:arbor_memory] || [], @route_key) == :error
    existing = [enabled: true, model: "explicit-test-fixture"]
    merged = Reader.merge([arbor_memory: [{@route_key, existing}]], runtime)
    assert merged[:arbor_memory][@route_key] == existing
  end

  test "test environment also ignores malformed inherited opt-in values", %{root: root} do
    for key <- @hybrid_keys, do: System.put_env(key, "malformed-fixture-value")
    runtime = read_runtime(root, :test)
    assert Keyword.fetch(runtime[:arbor_memory] || [], @route_key) == :error
  end

  test "security regression: opt-in flags reject malformed values without echoing contents", %{
    root: root
  } do
    for value <- ["", "TRUE", "1", " true", "secret-fixture-do-not-log"] do
      System.put_env("ARBOR_HYBRID_MEMORY_ENABLED", value)

      assert_raise RuntimeError, "ARBOR_HYBRID_MEMORY_ENABLED must be true or false", fn ->
        read_runtime(root)
      end
    end
  end

  test "security regression: persistent enablement requires a supported explicit selector", %{
    root: root
  } do
    for value <- [nil, "", "ollama", "openai", "LM_Studio", "secret-fixture-do-not-log"] do
      put_enabled()
      put_or_delete("ARBOR_HYBRID_MEMORY_SELECTOR_PROVIDER", value)

      assert_raise RuntimeError, "ARBOR_HYBRID_MEMORY_SELECTOR_PROVIDER must be lm_studio", fn ->
        read_runtime(root)
      end
    end
  end

  test "security regression: embedding provider cannot select an undeclared route", %{root: root} do
    for value <- [nil, "", "openai", "Ollama", "secret-fixture-do-not-log"] do
      put_enabled()
      put_or_delete("ARBOR_HYBRID_MEMORY_PROVIDER", value)

      assert_raise RuntimeError, "ARBOR_HYBRID_MEMORY_PROVIDER must be ollama or lm_studio", fn ->
        read_runtime(root)
      end
    end
  end

  test "enabled embedding and selector labels are required and bounded by UTF-8 bytes", %{
    root: root
  } do
    for {key, maximum} <- [
          {"ARBOR_HYBRID_MEMORY_MODEL", 256},
          {"ARBOR_HYBRID_MEMORY_BASE_URL", 4_096},
          {"ARBOR_HYBRID_MEMORY_SELECTOR_MODEL", 256},
          {"ARBOR_HYBRID_MEMORY_SELECTOR_BASE_URL", 4_096}
        ],
        value <- [
          nil,
          "",
          " ",
          " leading",
          "trailing ",
          String.duplicate("s", maximum + 1),
          String.duplicate("é", div(maximum, 2) + 1)
        ] do
      put_enabled()
      put_or_delete(key, value)

      expected =
        "#{key} must be a nonempty UTF-8 value without surrounding whitespace (at most #{maximum} bytes)"

      assert_raise RuntimeError, expected, fn -> read_runtime(root) end
    end
  end

  test "security regression: timeout and candidate limits require whole bounded integers", %{
    root: root
  } do
    for {key, maximum} <- [
          {"ARBOR_HYBRID_MEMORY_TIMEOUT_MS", 30_000},
          {"ARBOR_HYBRID_MEMORY_SELECTOR_TIMEOUT_MS", 20_000},
          {"ARBOR_HYBRID_MEMORY_CANDIDATE_LIMIT", 8}
        ],
        value <- [
          "0",
          "-1",
          Integer.to_string(maximum + 1),
          "1.5",
          "1s",
          "1 ",
          "",
          "secret-fixture-do-not-log"
        ] do
      put_enabled()
      System.put_env(key, value)
      expected = "#{key} must be an integer between 1 and #{maximum}"
      assert_raise RuntimeError, expected, fn -> read_runtime(root) end
    end
  end

  test "security regression: numeric thresholds reject suffixes nonfinite values and overflow", %{
    root: root
  } do
    for key <- unit_keys(),
        value <- [
          "-0.1",
          "1.01",
          "0.7junk",
          " 0.7",
          "0.7 ",
          "NaN",
          "Infinity",
          "1.0e999",
          "",
          String.duplicate("9", 65)
        ] do
      put_enabled()
      System.put_env(key, value)

      assert_raise RuntimeError, "#{key} must be a finite number between 0 and 1", fn ->
        read_runtime(root)
      end
    end
  end

  test "hybrid settings do not rewrite private memory or canonical provider endpoints", %{
    root: root
  } do
    put_enabled()
    System.put_env("ARBOR_PRIVATE_MEMORY_ENABLED", "true")
    System.put_env("ARBOR_PRIVATE_MEMORY_PROVIDER", "ollama")
    System.put_env("ARBOR_PRIVATE_MEMORY_MODEL", "separate-private-model")
    System.put_env("ARBOR_PRIVATE_MEMORY_BASE_URL", "http://127.0.0.2:11434/v1")
    System.put_env("ARBOR_OLLAMA_CHAT_BASE_URL", "http://127.0.0.3:11434/v1")
    runtime = read_runtime(root)
    assert route(runtime)[:base_url] == @embedding_base
    assert route(runtime)[:selector][:base_url] == @selector_base

    assert runtime[:arbor_orchestrator][:private_conversation_memory][:model] ==
             "separate-private-model"

    assert runtime[:arbor_orchestrator][:private_conversation_memory][:base_url] ==
             "http://127.0.0.2:11434/v1"

    assert runtime[:arbor_orchestrator][:ollama][:base_url] == "http://127.0.0.3:11434/v1"
    assert Keyword.fetch(runtime[:arbor_llm] || [], :trusted_proxy_endpoints) == :error
  end

  test "explicit LM Studio endpoint reaches the public endpoint owner without trusting a search URL",
       %{root: root} do
    put_enabled()
    Application.delete_env(:arbor_llm, :trusted_proxy_endpoints)
    Application.delete_env(:arbor_orchestrator, :lm_studio)
    runtime = read_runtime(root)
    assert Keyword.fetch(runtime[:arbor_orchestrator] || [], :lm_studio) == :error

    assert {:error, :endpoint_origin_not_trusted} =
             Arbor.LLM.validate_endpoint(@selector_base, {:req_llm_base, "lm_studio"})

    System.put_env("ARBOR_LM_STUDIO_BASE_URL", @selector_base)
    runtime = read_runtime(root)
    assert runtime[:arbor_orchestrator][:lm_studio] == [base_url: @selector_base]
    Application.put_env(:arbor_orchestrator, :lm_studio, runtime[:arbor_orchestrator][:lm_studio])

    assert {:ok, @selector_base} =
             Arbor.LLM.validate_endpoint(@selector_base, {:req_llm_base, "lm_studio"})

    assert {:error, :endpoint_origin_not_trusted} =
             Arbor.LLM.validate_endpoint("http://127.0.0.2:1234/v1", {:req_llm_base, "lm_studio"})

    assert Keyword.fetch(runtime[:arbor_llm] || [], :trusted_proxy_endpoints) == :error
  end

  test "LM Studio endpoint bridge preserves unset and test configuration and refuses malformed labels",
       %{root: root} do
    existing = [arbor_orchestrator: [lm_studio: [base_url: "http://127.0.0.2:1234/v1"]]]

    assert Reader.merge(existing, read_runtime(root))[:arbor_orchestrator][:lm_studio] ==
             existing[:arbor_orchestrator][:lm_studio]

    System.put_env("ARBOR_LM_STUDIO_BASE_URL", @selector_base)

    assert Reader.merge(existing, read_runtime(root, :test))[:arbor_orchestrator][:lm_studio] ==
             existing[:arbor_orchestrator][:lm_studio]

    for value <- ["", " leading", "trailing ", String.duplicate("x", 4097)] do
      System.put_env("ARBOR_LM_STUDIO_BASE_URL", value)

      assert_raise RuntimeError,
                   "ARBOR_LM_STUDIO_BASE_URL must be a nonempty UTF-8 URL without surrounding whitespace (at most 4096 bytes)",
                   fn -> read_runtime(root) end
    end
  end

  defp unit_keys,
    do:
      ~w(ARBOR_HYBRID_MEMORY_MIN_COSINE ARBOR_HYBRID_MEMORY_MIN_SCORE ARBOR_HYBRID_MEMORY_SEMANTIC_WEIGHT)

  defp put_enabled do
    Enum.each(@hybrid_keys, &System.delete_env/1)
    System.put_env("ARBOR_HYBRID_MEMORY_ENABLED", "true")
    System.put_env("ARBOR_HYBRID_MEMORY_PROVIDER", "ollama")
    System.put_env("ARBOR_HYBRID_MEMORY_MODEL", "fixture-embedding-model")
    System.put_env("ARBOR_HYBRID_MEMORY_BASE_URL", @embedding_base)
    System.put_env("ARBOR_HYBRID_MEMORY_SELECTOR_PROVIDER", "lm_studio")
    System.put_env("ARBOR_HYBRID_MEMORY_SELECTOR_MODEL", "fixture-selector-model")
    System.put_env("ARBOR_HYBRID_MEMORY_SELECTOR_BASE_URL", @selector_base)
  end

  defp put_or_delete(key, nil), do: System.delete_env(key)
  defp put_or_delete(key, value), do: System.put_env(key, value)
  defp route(runtime), do: (runtime[:arbor_memory] || [])[@route_key]

  defp write_dotenv(root) do
    File.write!(Path.join(root, ".env"), """
    ARBOR_HYBRID_MEMORY_ENABLED=true
    ARBOR_HYBRID_MEMORY_PROVIDER=ollama
    ARBOR_HYBRID_MEMORY_MODEL=dotenv-embedding
    ARBOR_HYBRID_MEMORY_BASE_URL=#{@embedding_base}
    ARBOR_HYBRID_MEMORY_SELECTOR_PROVIDER=lm_studio
    ARBOR_HYBRID_MEMORY_SELECTOR_MODEL=dotenv-selector
    ARBOR_HYBRID_MEMORY_SELECTOR_BASE_URL=#{@selector_base}
    ARBOR_HYBRID_MEMORY_CANDIDATE_LIMIT=4
    """)
  end

  defp read_runtime(root, env \\ :dev) do
    File.cd!(root, fn -> Reader.read!(@runtime_path, env: env, target: :host) end)
  end
end
