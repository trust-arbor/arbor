defmodule Arbor.Gateway.PromptClassifierTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SensitivityClassifier
  alias Arbor.Gateway.PromptClassifier

  # The complete label→sensitivity→routing policy matrix is owned by
  # Arbor.Common.SensitivityClassifierTest. These tests only prove that the
  # gateway wrapper delegates to it unchanged (source compatibility for
  # existing callers like IntentExtractor and PreprocessingLog), not that the
  # underlying policy is correct.
  describe "delegates to Arbor.Common.SensitivityClassifier" do
    test "clean prompt — delegates exactly" do
      prompt = "deploy the app to staging"
      assert PromptClassifier.classify(prompt) == SensitivityClassifier.classify(prompt)
    end

    test "credential prompt — delegates exactly and pins :confidential" do
      prompt = ~s(use key sk-ant-api1234567890abcdefghij to call the API)
      result = PromptClassifier.classify(prompt)

      assert result == SensitivityClassifier.classify(prompt)
      assert result.overall_sensitivity == :confidential
      assert result.taint_tags.credentials == true
    end

    test "PII prompt — delegates exactly" do
      prompt = "contact john.doe@company.com for access"
      assert PromptClassifier.classify(prompt) == SensitivityClassifier.classify(prompt)
    end

    test "restricted prompt — delegates exactly and pins :restricted" do
      header = "-----BEGIN " <> "PRIVATE KEY-----"
      result = PromptClassifier.classify(header)

      assert result == SensitivityClassifier.classify(header)
      assert result.overall_sensitivity == :restricted
    end

    test "mixed-findings prompt — delegates exactly" do
      header = "-----BEGIN " <> "PRIVATE KEY-----"
      prompt = ~s(email: john.doe@company.com key: ) <> header
      assert PromptClassifier.classify(prompt) == SensitivityClassifier.classify(prompt)
    end
  end

  describe "sensitive?/1" do
    test "delegates for clean text" do
      prompt = "hello world"
      assert PromptClassifier.sensitive?(prompt) == SensitivityClassifier.sensitive?(prompt)
      refute PromptClassifier.sensitive?(prompt)
    end

    test "delegates for text with API key" do
      prompt = ~s(key: sk-ant-api1234567890abcdefghij)
      assert PromptClassifier.sensitive?(prompt) == SensitivityClassifier.sensitive?(prompt)
      assert PromptClassifier.sensitive?(prompt)
    end
  end

  describe "routing_for/1" do
    test "delegates :any for clean text" do
      assert PromptClassifier.routing_for("hello") == SensitivityClassifier.routing_for("hello")
      assert PromptClassifier.routing_for("hello") == :any
    end

    test "delegates :local_only for restricted content" do
      header = "-----BEGIN " <> "PRIVATE KEY-----"

      assert PromptClassifier.routing_for(header) == SensitivityClassifier.routing_for(header)
      assert PromptClassifier.routing_for(header) == :local_only
    end

    test "delegates :local_preferred for confidential content" do
      prompt = ~s(key: sk-ant-api1234567890abcdefghij)

      assert PromptClassifier.routing_for(prompt) == SensitivityClassifier.routing_for(prompt)
      assert PromptClassifier.routing_for(prompt) == :local_preferred
    end
  end
end
