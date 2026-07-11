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
end
