defmodule Arbor.LLM.OAuthTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.OAuth

  describe "Anthropic guardrail (security regression — never wire a Claude subscription, ToS)" do
    test "refuses every anthropic/claude-family provider spelling BEFORE any token read" do
      for p <- [
            :anthropic,
            :claude,
            :"claude-code",
            :claude_code,
            "claude",
            "anthropic",
            "Claude",
            "CLAUDE-CODE",
            "anthropic/claude-opus-4"
          ] do
        assert {:error, :anthropic_oauth_forbidden} = OAuth.access_token(p),
               "expected #{inspect(p)} to be refused"

        assert OAuth.account_id(p) == nil
        refute OAuth.available?(p)
      end
    end
  end

  describe "provider resolution" do
    test "unknown providers error cleanly (no crash)" do
      # :mistral/:cohere aren't OAuth providers → resolve fails BEFORE any file read/refresh.
      assert {:error, {:no_oauth_provider, _}} = OAuth.access_token(:mistral)
      assert {:error, {:no_oauth_provider, _}} = OAuth.access_token("cohere")
    end

    # NOTE: we deliberately do NOT call access_token(:xai)/(:grok) in tests — it refreshes against
    # the OAuth token endpoint (network) and providers ROTATE the refresh_token, which would consume
    # + invalidate the user's grok CLI credential. openai reads a cached token (no refresh) but still
    # does file I/O, so it's exercised only in the manual verify below, not the async suite.
  end
end
