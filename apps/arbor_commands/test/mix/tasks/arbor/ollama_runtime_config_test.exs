defmodule Mix.Tasks.Arbor.OllamaRuntimeConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @runtime_path Path.expand("../../../../../../config/runtime.exs", __DIR__)
  @env_keys ~w(ARBOR_OLLAMA_BASE_URL ARBOR_OLLAMA_CHAT_BASE_URL OLLAMA_API_KEY)

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)
    root = Path.join(System.tmp_dir!(), "ollama-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "defaults leave chat and embeddings local", %{root: root} do
    config = read_runtime(root)
    assert config[:arbor_ai][:ollama][:base_url] == "http://localhost:11434"
    assert config[:arbor_orchestrator][:ollama][:base_url] == "http://localhost:11434/v1"
  end

  test "shared legacy URL still configures both paths", %{root: root} do
    System.put_env("ARBOR_OLLAMA_BASE_URL", "http://ollama.internal:11434")
    config = read_runtime(root)
    assert config[:arbor_ai][:ollama][:base_url] == "http://ollama.internal:11434"
    assert config[:arbor_orchestrator][:ollama][:base_url] == "http://ollama.internal:11434/v1"
  end

  test "cloud council configuration does not redirect embeddings", %{root: root} do
    System.put_env("ARBOR_OLLAMA_CHAT_BASE_URL", "https://ollama.com")
    System.put_env("OLLAMA_API_KEY", "test-only-not-a-credential")
    config = read_runtime(root)
    assert config[:arbor_ai][:ollama][:base_url] == "http://localhost:11434"
    assert config[:arbor_ai][:ollama][:api_key] == nil
    assert config[:arbor_orchestrator][:ollama][:base_url] == "https://ollama.com/v1"
    assert config[:arbor_orchestrator][:ollama][:api_key] == "test-only-not-a-credential"
  end

  test "chat override preserves its v1 suffix and the separate embedding URL", %{root: root} do
    System.put_env("ARBOR_OLLAMA_BASE_URL", "http://ollama.internal:11434")
    System.put_env("ARBOR_OLLAMA_CHAT_BASE_URL", "https://ollama.com/v1")
    config = read_runtime(root)
    assert config[:arbor_ai][:ollama][:base_url] == "http://ollama.internal:11434"
    assert config[:arbor_orchestrator][:ollama][:base_url] == "https://ollama.com/v1"
  end

  test "blank chat override falls back to the shared URL", %{root: root} do
    System.put_env("ARBOR_OLLAMA_BASE_URL", "http://ollama.internal:11434")
    System.put_env("ARBOR_OLLAMA_CHAT_BASE_URL", "")
    config = read_runtime(root)
    assert config[:arbor_orchestrator][:ollama][:base_url] == "http://ollama.internal:11434/v1"
  end

  defp read_runtime(root) do
    # No ambient .env, Application configuration mutation, or provider calls.
    File.cd!(root, fn -> Config.Reader.read!(@runtime_path, env: :test, target: :host) end)
  end
end
