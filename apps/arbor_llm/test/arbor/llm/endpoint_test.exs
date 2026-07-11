defmodule Arbor.LLM.EndpointTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Endpoint

  setup do
    proxy_config = Application.get_env(:arbor_llm, :trusted_proxy_endpoints)
    lm_studio = Application.get_env(:arbor_llm, :lm_studio_base_url)

    on_exit(fn ->
      restore_env(:trusted_proxy_endpoints, proxy_config)
      restore_env(:lm_studio_base_url, lm_studio)
    end)

    :ok
  end

  test "security regression: validates original authority before canonicalization" do
    for endpoint <- [
          "http://host:abc/v1",
          "http://host:/v1",
          "http://[::1]x/v1",
          "http://[::1]:abc/v1",
          "http://user@host/v1",
          "http://user%40host/v1",
          "http://host:80:90/v1",
          "http://bad host/v1",
          "http://host\\@evil/v1",
          "http://127.1/v1",
          "http://2130706433/v1",
          "http://0177.0.0.1/v1",
          "http://0x7f000001/v1"
        ] do
      assert {:error, _reason} = Endpoint.validate(endpoint, :req_llm_base)
    end
  end

  test "canonical endpoint retains the exact validated authority" do
    assert {:ok, "https://api.openai.com/v1"} =
             Endpoint.validate("https://API.OPENAI.com/v1/", {:req_llm_base, "openai"})

    Application.put_env(:arbor_llm, :lm_studio_base_url, "http://[::1]:1234/v1")

    assert {:ok, "http://[::1]:1234/v1"} =
             Endpoint.validate("http://[::1]:1234/v1", :lm_studio)

    assert {:ok, "http://localhost:11434/v1/embeddings"} =
             Endpoint.validate("http://LOCALHOST:11434/v1/embeddings", :embedding)
  end

  test "security regression: path, query, fragment, and credential ambiguity is rejected" do
    for endpoint <- [
          "http://example.test/v1/../admin",
          "http://example.test/v1%2fadmin",
          "http://example.test/v1?next=evil",
          "http://example.test/v1#fragment",
          "ftp://example.test/v1"
        ] do
      assert {:error, _reason} = Endpoint.validate(endpoint, :req_llm_base)
    end
  end

  test "provider-aware base paths accept documented Azure, Google, and reviewed proxy URLs" do
    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
      "azure" => ["https://resource.openai.azure.com/openai"],
      "openai" => ["https://proxy.example.test/tenant/llm/v1"]
    })

    assert {:ok, "https://resource.openai.azure.com/openai"} =
             Endpoint.validate(
               "https://resource.openai.azure.com/openai/",
               {:req_llm_base, :azure}
             )

    assert {:ok, "https://generativelanguage.googleapis.com/v1beta"} =
             Endpoint.validate(
               "https://generativelanguage.googleapis.com/v1beta",
               {:req_llm_base, "google"}
             )

    assert {:ok, "https://proxy.example.test/tenant/llm/v1"} =
             Endpoint.validate(
               "https://proxy.example.test/tenant/llm/v1/",
               {:req_llm_base, "openai"}
             )
  end

  test "security regression: provider-aware paths cannot widen, duplicate suffixes, or traverse" do
    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
      "azure" => ["https://resource.openai.azure.com/openai"],
      "openai" => ["https://proxy.example.test/tenant/llm/v1"]
    })

    for endpoint <- [
          "https://resource.openai.azure.com/openai/chat/completions",
          "https://resource.openai.azure.com/openai/../admin",
          "https://resource.openai.azure.com/openai//",
          "https://resource.openai.azure.com/openai%2fadmin",
          "https://resource.openai.azure.com/v1",
          "https://user@resource.openai.azure.com/openai",
          "https://resource.openai.azure.com/openai?next=/admin",
          "https://resource.openai.azure.com/openai#fragment"
        ] do
      assert {:error, _reason} = Endpoint.validate(endpoint, {:req_llm_base, "azure"})
    end

    assert {:error, _reason} =
             Endpoint.validate(
               "https://proxy.example.test/tenant/llm/admin",
               {:req_llm_base, "openai"}
             )

    assert {:error, :invalid_endpoint_policy} =
             Endpoint.validate(
               "https://proxy.example.test/tenant/llm/v1",
               {:req_llm_base, "openai", ["/tenant/llm/v1"]}
             )
  end

  test "security regression: callers cannot authorize metadata or arbitrary proxy origins" do
    for endpoint <- [
          "http://169.254.169.254/v1",
          "http://10.0.0.5/v1",
          "http://127.0.0.1:8080/v1",
          "https://attacker.example/v1"
        ] do
      assert {:error, :endpoint_origin_not_trusted} =
               Endpoint.validate(endpoint, {:req_llm_base, "openai"})
    end

    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
      "openai" => ["https://proxy.example.test/tenant/v1"]
    })

    assert {:ok, "https://proxy.example.test/tenant/v1"} =
             Endpoint.validate(
               "https://proxy.example.test/tenant/v1",
               {:req_llm_base, "openai"}
             )

    assert {:error, :endpoint_origin_not_trusted} =
             Endpoint.validate("https://attacker.example/tenant/v1", {:req_llm_base, "openai"})
  end

  test "security regression: malformed endpoint policy data is total and bounded" do
    assert {:error, :invalid_endpoint_policy} =
             Endpoint.validate(
               "https://api.openai.com/v1",
               {:req_llm_base, String.duplicate("p", 257)}
             )

    assert {:error, :bounded_string_required} = Endpoint.validate(%URI{}, :oauth_responses)

    assert {:error, :invalid_endpoint_policy} =
             Endpoint.validate("https://api.openai.com/v1", {:req_llm_base, %{}})
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_llm, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_llm, key, value)
end
