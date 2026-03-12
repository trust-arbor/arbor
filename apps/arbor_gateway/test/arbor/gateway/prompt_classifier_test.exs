defmodule Arbor.Gateway.PromptClassifierTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Gateway.PromptClassifier

  describe "classify/1" do
    test "returns :public for clean prompt" do
      result = PromptClassifier.classify("deploy the app to staging")

      assert result.overall_sensitivity == :public
      assert result.routing_recommendation == :any
      assert result.findings == []
      assert result.element_count == 0
      assert result.sanitized_prompt == "deploy the app to staging"
      assert result.taint_tags == %{pii: false, credentials: false, code: false, internal: false}
    end

    test "detects API key and classifies as :confidential" do
      prompt = ~s(use key sk-ant-api1234567890abcdefghij to call the API)
      result = PromptClassifier.classify(prompt)

      assert result.overall_sensitivity == :confidential
      assert result.routing_recommendation == :local_preferred
      assert result.element_count >= 1
      assert result.taint_tags.credentials == true
      assert result.sanitized_prompt =~ "[REDACTED]"
      refute result.sanitized_prompt =~ "sk-ant-"
    end

    test "detects private key and classifies as :restricted" do
      prompt = "here is my key:\n-----BEGIN RSA PRIVATE KEY-----\ndata"
      result = PromptClassifier.classify(prompt)

      assert result.overall_sensitivity == :restricted
      assert result.routing_recommendation == :local_only
      assert result.taint_tags.credentials == true
    end

    test "detects database connection string as :restricted" do
      prompt = "connect to postgres://admin:secret@db.example.com/mydb"
      result = PromptClassifier.classify(prompt)

      assert result.overall_sensitivity == :restricted
      assert result.routing_recommendation == :local_only
    end

    test "detects password in config as :confidential" do
      prompt = ~s(set password = "hunter2secret")
      result = PromptClassifier.classify(prompt)

      assert result.overall_sensitivity == :confidential
      assert result.taint_tags.credentials == true
    end

    test "detects PII — email address" do
      prompt = "contact john.doe@company.com for access"
      result = PromptClassifier.classify(prompt)

      assert result.element_count >= 1
      assert result.taint_tags.pii == true
      assert result.sanitized_prompt =~ "[REDACTED]"
    end

    test "detects SSN as :restricted with PII tag" do
      prompt = "my SSN is 123-45-6789"
      result = PromptClassifier.classify(prompt)

      assert result.overall_sensitivity == :restricted
      assert result.routing_recommendation == :local_only
      assert result.taint_tags.pii == true
    end

    test "handles mixed findings — takes highest sensitivity" do
      prompt = ~s(email: john.doe@company.com key: -----BEGIN PRIVATE KEY-----)
      result = PromptClassifier.classify(prompt)

      # Private key = :restricted, email = :internal → max is :restricted
      assert result.overall_sensitivity == :restricted
      assert result.taint_tags.pii == true
      assert result.taint_tags.credentials == true
    end

    test "sanitized_prompt matches original when no findings" do
      prompt = "plain request with no secrets"
      result = PromptClassifier.classify(prompt)

      assert result.sanitized_prompt == prompt
    end
  end

  describe "sensitive?/1" do
    test "returns false for clean text" do
      refute PromptClassifier.sensitive?("hello world")
    end

    test "returns true for text with API key" do
      assert PromptClassifier.sensitive?(~s(key: sk-ant-api1234567890abcdefghij))
    end
  end

  describe "routing_for/1" do
    test "returns :any for clean text" do
      assert PromptClassifier.routing_for("hello") == :any
    end

    test "returns :local_only for restricted content" do
      assert PromptClassifier.routing_for("-----BEGIN PRIVATE KEY-----") == :local_only
    end

    test "returns :local_preferred for confidential content" do
      assert PromptClassifier.routing_for(~s(key: sk-ant-api1234567890abcdefghij)) == :local_preferred
    end
  end
end
