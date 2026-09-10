defmodule Arbor.Orchestrator.PrivateMemoryRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Config.Reader

  @moduletag :fast
  @runtime_path Path.expand("../../../../../config/runtime.exs", __DIR__)
  @private_keys ~w(ARBOR_PRIVATE_MEMORY_ENABLED ARBOR_PRIVATE_MEMORY_PROVIDER ARBOR_PRIVATE_MEMORY_MODEL ARBOR_PRIVATE_MEMORY_BASE_URL ARBOR_PRIVATE_MEMORY_TIMEOUT_MS)
  @env_keys @private_keys ++
              ~w(ARBOR_HOME ARBOR_VALIDATION_RUNTIME_CONFIG_PATH ARBOR_APPLE_CONTAINER_CONFIG_PATH ARBOR_OLLAMA_BASE_URL ARBOR_OLLAMA_CHAT_BASE_URL OLLAMA_API_KEY)
  @route_key :private_conversation_memory
  @base_url "http://127.0.0.1:11434/v1"

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    root =
      Path.join(System.tmp_dir!(), "private-memory-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    System.put_env("ARBOR_HOME", root)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "unset flag preserves explicit application configuration and the disabled default", %{
    root: root
  } do
    System.put_env("ARBOR_PRIVATE_MEMORY_PROVIDER", "ignored-without-opt-in")
    runtime = read_runtime(root)
    assert Keyword.fetch(runtime[:arbor_orchestrator], @route_key) == :error

    for existing <- [false, [enabled: true, model: "programmatic-route"]] do
      configured = Reader.merge([arbor_orchestrator: [{@route_key, existing}]], runtime)
      assert configured[:arbor_orchestrator][@route_key] == existing
    end
  end

  test "explicit false disables a configured route without requiring companion values", %{
    root: root
  } do
    System.put_env("ARBOR_PRIVATE_MEMORY_ENABLED", "false")
    System.put_env("ARBOR_PRIVATE_MEMORY_TIMEOUT_MS", "ignored-while-disabled")
    runtime = read_runtime(root)
    assert runtime[:arbor_orchestrator][@route_key] === false

    configured =
      Reader.merge(
        [arbor_orchestrator: [{@route_key, [enabled: true, model: "previous-route"]}]],
        runtime
      )

    assert configured[:arbor_orchestrator][@route_key] === false
  end

  test "explicit Ollama route uses the exact existing keys and default timeout", %{root: root} do
    put_enabled()
    runtime = read_runtime(root)

    assert runtime[:arbor_orchestrator][@route_key] == [
             enabled: true,
             provider: :ollama,
             model: "fixture-embedding-model",
             base_url: @base_url,
             timeout_ms: 10_000
           ]
  end

  test "LM Studio provider mapping and timeout endpoints are explicit", %{root: root} do
    put_enabled()
    System.put_env("ARBOR_PRIVATE_MEMORY_PROVIDER", "lm_studio")
    System.put_env("ARBOR_PRIVATE_MEMORY_BASE_URL", "http://127.0.0.1:1234/v1")

    for timeout <- [1, 30_000] do
      System.put_env("ARBOR_PRIVATE_MEMORY_TIMEOUT_MS", Integer.to_string(timeout))
      route = read_runtime(root)[:arbor_orchestrator][@route_key]
      assert route[:provider] == :lm_studio
      assert route[:timeout_ms] == timeout
      assert route[:base_url] == "http://127.0.0.1:1234/v1"
    end
  end

  test "dev dotenv is read before the private-memory bridge", %{root: root} do
    write_dotenv(root)
    route = read_runtime(root)[:arbor_orchestrator][@route_key]
    assert route[:enabled] === true
    assert route[:model] == "fixture-dotenv-model"
    assert route[:timeout_ms] == 30_000
  end

  test "security regression: test environment ignores private values loaded from dotenv", %{
    root: root
  } do
    write_dotenv(root)
    runtime = read_runtime(root, :test)
    # The existing global dotenv loader is unchanged and really loaded this.
    assert System.get_env("ARBOR_PRIVATE_MEMORY_ENABLED") == "true"
    assert Keyword.fetch(runtime[:arbor_orchestrator], @route_key) == :error

    existing = [enabled: true, model: "explicit-test-fixture"]
    configured = Reader.merge([arbor_orchestrator: [{@route_key, existing}]], runtime)
    assert configured[:arbor_orchestrator][@route_key] == existing
  end

  test "test environment also ignores malformed inherited private values", %{root: root} do
    for key <- @private_keys, do: System.put_env(key, "malformed-private-fixture-value")
    runtime = read_runtime(root, :test)
    assert Keyword.fetch(runtime[:arbor_orchestrator], @route_key) == :error
  end

  test "security regression: malformed opt-in values fail without echoing their contents", %{
    root: root
  } do
    for value <- ["", "TRUE", "1", " true", "secret-fixture-do-not-log"] do
      System.put_env("ARBOR_PRIVATE_MEMORY_ENABLED", value)

      assert_raise RuntimeError, "ARBOR_PRIVATE_MEMORY_ENABLED must be true or false", fn ->
        read_runtime(root)
      end
    end
  end

  test "security regression: enabled routes require a supported explicit provider", %{root: root} do
    for value <- [nil, "", "openai", "Ollama", "secret-fixture-do-not-log"] do
      put_enabled()
      put_or_delete("ARBOR_PRIVATE_MEMORY_PROVIDER", value)

      assert_raise RuntimeError,
                   "ARBOR_PRIVATE_MEMORY_PROVIDER must be ollama or lm_studio",
                   fn ->
                     read_runtime(root)
                   end
    end
  end

  test "enabled routes require bounded model and base URL labels", %{root: root} do
    for {key, max_bytes} <- [
          {"ARBOR_PRIVATE_MEMORY_MODEL", 256},
          {"ARBOR_PRIVATE_MEMORY_BASE_URL", 4_096}
        ],
        value <- [nil, "", " ", " leading", "trailing ", String.duplicate("s", max_bytes + 1)] do
      put_enabled()
      put_or_delete(key, value)

      expected =
        "#{key} must be a nonempty UTF-8 value without surrounding whitespace (at most #{max_bytes} bytes)"

      assert_raise RuntimeError, expected, fn -> read_runtime(root) end
    end
  end

  test "security regression: malformed or out-of-range timeout cannot enable a route", %{
    root: root
  } do
    for value <- ["0", "30001", "-1", "1.5", "30s", "", "secret-fixture-do-not-log"] do
      put_enabled()
      System.put_env("ARBOR_PRIVATE_MEMORY_TIMEOUT_MS", value)

      assert_raise RuntimeError,
                   "ARBOR_PRIVATE_MEMORY_TIMEOUT_MS must be an integer between 1 and 30000",
                   fn -> read_runtime(root) end
    end
  end

  test "private route does not rewrite the existing provider registry endpoint", %{root: root} do
    put_enabled()
    configured_endpoint = "http://127.0.0.2:11434/v1"
    System.put_env("ARBOR_OLLAMA_CHAT_BASE_URL", configured_endpoint)
    runtime = read_runtime(root)
    assert runtime[:arbor_orchestrator][@route_key][:base_url] == @base_url
    assert runtime[:arbor_orchestrator][:ollama][:base_url] == configured_endpoint

    System.put_env("ARBOR_OLLAMA_CHAT_BASE_URL", @base_url)
    matched = read_runtime(root)
    assert matched[:arbor_orchestrator][:ollama][:base_url] == @base_url
  end

  defp put_enabled do
    System.put_env("ARBOR_PRIVATE_MEMORY_ENABLED", "true")
    System.put_env("ARBOR_PRIVATE_MEMORY_PROVIDER", "ollama")
    System.put_env("ARBOR_PRIVATE_MEMORY_MODEL", "fixture-embedding-model")
    System.put_env("ARBOR_PRIVATE_MEMORY_BASE_URL", @base_url)
    System.delete_env("ARBOR_PRIVATE_MEMORY_TIMEOUT_MS")
  end

  defp put_or_delete(key, nil), do: System.delete_env(key)
  defp put_or_delete(key, value), do: System.put_env(key, value)

  defp write_dotenv(root) do
    File.write!(Path.join(root, ".env"), """
    ARBOR_PRIVATE_MEMORY_ENABLED=true
    ARBOR_PRIVATE_MEMORY_PROVIDER=ollama
    ARBOR_PRIVATE_MEMORY_MODEL=fixture-dotenv-model
    ARBOR_PRIVATE_MEMORY_BASE_URL=#{@base_url}
    ARBOR_PRIVATE_MEMORY_TIMEOUT_MS=30000
    """)
  end

  defp read_runtime(root, env \\ :dev) do
    # Actual runtime config, an owned cwd/.env and ARBOR_HOME, no provider calls.
    File.cd!(root, fn -> Reader.read!(@runtime_path, env: env, target: :host) end)
  end
end
