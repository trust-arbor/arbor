defmodule Arbor.LLM.Host.ModelProfileCompositionTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.OpenCodeZen

  test "every admitted model has a ModelProfile with its recorded context window" do
    for record <- OpenCodeZen.admitted() do
      id = record["id"]
      profile = Arbor.Common.ModelProfile.get(id)

      # The relay publishes no context window, and inventing one is exactly the
      # defect this catalog exists to prevent — so a record may legitimately
      # omit it and rely on ModelProfile's conservative default. Assert the
      # match only where a window was actually recorded.
      case record["context_window"] do
        nil ->
          assert is_integer(profile.context_size) and profile.context_size > 0,
                 "ModelProfile default must still yield a usable window for #{id}"

        recorded ->
          assert profile.context_size == recorded,
                 "wrong ModelProfile context window for admitted model #{id}"
      end
    end
  end
end
