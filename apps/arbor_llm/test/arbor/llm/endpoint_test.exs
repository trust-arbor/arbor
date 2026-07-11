defmodule Arbor.LLM.EndpointTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.Endpoint

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
    assert {:ok, "http://example.test:8080/v1"} =
             Endpoint.validate("http://EXAMPLE.test:8080/v1/", :req_llm_base)

    assert {:ok, "http://[::1]:1234/v1"} =
             Endpoint.validate("http://[::1]:1234/v1", :lm_studio)

    assert {:ok, "http://[::1]/v1"} =
             Endpoint.validate("http://[0:0:0:0:0:0:0:1]/v1", :lm_studio)

    assert {:ok, "https://embedding.test/v1/embeddings"} =
             Endpoint.validate("https://embedding.test/v1/embeddings", :embedding)
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
               {:req_llm_base, "openai", ["/tenant/llm/v1"]}
             )
  end

  test "security regression: provider-aware paths cannot widen, duplicate suffixes, or traverse" do
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
               {:req_llm_base, "openai", ["/tenant/llm/v1"]}
             )

    for reviewed <- [
          "/tenant/../admin",
          "/tenant/%2e%2e/admin",
          "/tenant/chat/completions",
          "tenant/v1"
        ] do
      assert {:error, _reason} =
               Endpoint.validate(
                 "https://proxy.example.test/tenant/v1",
                 {:req_llm_base, "openai", [reviewed]}
               )
    end
  end
end
