defmodule Arbor.Contracts.Security.ReflexUrlContextSecurityRegressionTest do
  @moduledoc """
  Security regression: pattern reflexes must match documented URL context.

  `Arbor.Security.Reflex.check/1` documents that a cloud-metadata URL is
  blocked. Pattern matching previously inspected only `:command`, so a pure
  `%{url: ...}` context never fired.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Security.Reflex

  @metadata_url "http://169.254.169.254/latest/meta-data/"
  @ssrf_metadata_regex ~r/https?:\/\/169\.254\./

  test "security regression: pattern reflexes match URL context for cloud-metadata without treating URL as a command" do
    reflex =
      Reflex.pattern("ssrf_metadata", @ssrf_metadata_regex,
        id: "ssrf_metadata",
        response: :block
      )

    assert Reflex.matches?(reflex, %{url: @metadata_url})

    assert Reflex.matches?(reflex, %{command: "curl #{@metadata_url}"})
    refute Reflex.matches?(reflex, %{command: "echo hello"})
    refute Reflex.matches?(reflex, %{command: "echo hello", url: @metadata_url})
    refute Reflex.matches?(reflex, %{url: "http://example.com/"})
  end
end
