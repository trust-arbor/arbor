defmodule Arbor.Actions.CanonicalUriTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Actions
  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Security.UriRegistry

  @legacy_action_prefix "arbor://actions/execute"

  setup_all do
    unless Process.whereis(UriRegistry) do
      start_supervised!({UriRegistry, []})
    end

    Actions.register_action_uri_prefixes()
    :ok
  end

  describe "canonical_uri_for/2" do
    test "security regression: retired coding macro is not registered or discoverable" do
      refute Arbor.Actions.Coding.ProduceReviewableChange in Actions.all_actions()
      refute Arbor.Actions.Coding.ProduceReviewableChange in Actions.list_actions().coding

      assert {:error, :unknown_action} =
               Actions.name_to_module("coding_produce_reviewable_change")

      assert {:error, :unknown_action} =
               Actions.name_to_module("coding.produce_reviewable_change")

      refute "arbor://action/coding/produce_reviewable_change" in Actions.action_namespace_uri_prefixes()

      refute UriRegistry.registered?("arbor://action/coding/produce_reviewable_change")
    end

    test "registered actions do not use the retired plural action namespace" do
      legacy_uris =
        Actions.all_actions()
        |> Enum.map(&{&1, Actions.canonical_uri_for(&1, %{})})
        |> Enum.filter(fn {_module, uri} -> String.starts_with?(uri, @legacy_action_prefix) end)

      assert legacy_uris == []
    end

    test "git and github actions use schema-bounded action URIs instead of shell exec" do
      assert Actions.canonical_uri_for(Arbor.Actions.Git.Status, %{}) ==
               "arbor://action/git/status"

      assert Actions.canonical_uri_for(Arbor.Actions.Git.Commit, %{}) ==
               "arbor://action/git/commit"

      assert Actions.canonical_uri_for(Arbor.Actions.Git.PR, %{}) ==
               "arbor://action/git/pr"

      assert Actions.canonical_uri_for(Arbor.Actions.Github.PR, %{}) ==
               "arbor://action/github/pr"

      assert Actions.canonical_uri_for(Arbor.Actions.Council.ReviewChange, %{}) ==
               "arbor://action/council/review"
    end

    test "mix actions use schema-bounded action URIs instead of shell exec" do
      assert Actions.canonical_uri_for(Arbor.Actions.Mix.Compile, %{}) ==
               "arbor://action/mix/compile"

      assert Actions.canonical_uri_for(Arbor.Actions.Mix.Test, %{}) ==
               "arbor://action/mix/test"
    end

    test "unmapped schema-bounded actions derive a singular action URI" do
      assert Actions.canonical_uri_for(Arbor.Actions.Browser.Navigate, %{}) ==
               "arbor://action/browser/navigate"

      assert Actions.canonical_uri_for(Arbor.Actions.Security.RunDependencyScan, %{}) ==
               "arbor://action/security/run_dependency_scan"
    end

    test "facade actions still authorize through their resource facades" do
      assert Actions.canonical_uri_for(Arbor.Actions.File.Read, %{}) == "arbor://fs/read"
      assert Actions.canonical_uri_for(Arbor.Actions.Shell.Execute, %{}) == "arbor://shell/exec"
    end

    test "pipeline run and validate have distinct canonical action URIs" do
      assert Actions.canonical_uri_for(Arbor.Actions.Pipeline.Run, %{}) ==
               "arbor://action/pipeline/run"

      assert Actions.canonical_uri_for(Arbor.Actions.Pipeline.Validate, %{}) ==
               "arbor://action/pipeline/validate"
    end

    test "security regression validator is registered under its exact canonical URI" do
      validator = Arbor.Actions.Coding.SecurityRegression.Validate

      assert validator in Actions.all_actions()
      assert {:ok, ^validator} = Actions.name_to_module("coding_security_regression_validate")

      assert Actions.canonical_uri_for(validator, %{}) ==
               "arbor://action/coding/security_regression/validate"

      assert "arbor://action/coding/security_regression/validate" in Actions.action_namespace_uri_prefixes()
    end

    test "cross-app validator is registered under its exact canonical URI" do
      validator = Arbor.Actions.Coding.CrossApp.Validate

      assert validator in Actions.all_actions()
      assert {:ok, ^validator} = Actions.name_to_module("coding_cross_app_validate")

      assert Actions.canonical_uri_for(validator, %{}) ==
               "arbor://action/coding/cross_app/validate"

      assert "arbor://action/coding/cross_app/validate" in Actions.action_namespace_uri_prefixes()
    end

    test "review ledger decision action is registered under its exact canonical URI" do
      action = Arbor.Actions.Consensus.DecideReview

      assert action in Actions.all_actions()
      assert {:ok, ^action} = Actions.name_to_module("consensus_decide_review")

      assert Actions.canonical_uri_for(action, %{}) ==
               "arbor://action/consensus/decide_review"

      assert "arbor://action/consensus/decide_review" in Actions.action_namespace_uri_prefixes()
    end

    test "action namespace URI prefixes are generated and registered without a broad prefix" do
      prefixes = Actions.action_namespace_uri_prefixes()

      assert "arbor://action/git/status" in prefixes
      assert "arbor://action/git/pr" in prefixes
      assert "arbor://action/browser/navigate" in prefixes
      refute "arbor://fs/read" in prefixes
      refute "arbor://action" in Arbor.Security.canonical_uri_prefixes()

      assert Enum.all?(prefixes, &UriRegistry.registered?/1)
      refute UriRegistry.registered?("arbor://action/not_registered")
      refute UriRegistry.registered?("#{@legacy_action_prefix}/git.status")
    end

    test "generated action namespace prefixes have inline capability profiles" do
      profile_by_uri =
        Actions.action_namespace_capability_profiles()
        |> Map.new(&{&1.uri_prefix, &1})

      assert profile_by_uri |> Map.keys() |> Enum.sort() ==
               Actions.action_namespace_uri_prefixes()

      assert %CapabilityProfile{owner: :arbor_actions, effect_class: :read} =
               profile_by_uri["arbor://action/browser/navigate"]

      assert %CapabilityProfile{
               owner: :arbor_actions,
               effect_class: :process_spawn,
               default_approval: :require_human,
               graduation_eligible: false
             } =
               profile_by_uri["arbor://action/coding/security_regression/validate"]
    end

    test "generated action namespace profiles are visible to the trust registry" do
      assert %CapabilityProfile{owner: :arbor_actions, effect_class: :read} =
               Arbor.Trust.CapabilityProfileRegistry.profile_for(
                 "arbor://action/browser/navigate"
               )
    end
  end

  describe "tool_name_to_canonical_uri/1" do
    test "returns fallback singular action URIs for known unmapped tools" do
      assert Actions.tool_name_to_canonical_uri("browser.navigate") ==
               {:ok, "arbor://action/browser/navigate"}

      assert Actions.tool_name_to_canonical_uri("security_run_dependency_scan") ==
               {:ok, "arbor://action/security/run_dependency_scan"}
    end

    test "returns error for unknown tools instead of minting a URI string" do
      assert Actions.tool_name_to_canonical_uri("does.not.exist") == :error
    end
  end
end
