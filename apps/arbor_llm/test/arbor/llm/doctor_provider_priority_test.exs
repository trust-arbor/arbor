defmodule Arbor.LLM.DoctorProviderPriorityTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.ProviderRegistry

  # Lives here (L2) rather than in arbor_kernel_runtime (L1) so the membership
  # check can call ProviderRegistry without an upward L1 -> L2 dependency.
  test "every doctor catalog key is a known ProviderRegistry provider" do
    keys =
      Enum.map(Mix.Tasks.Arbor.Doctor.provider_priority(), fn {catalog_key, _, _} ->
        catalog_key
      end)

    # OpenRouter's registry name is "openrouter" (no underscore). That is
    # the req_llm / ProviderRegistry spelling; "open_router" is not a
    # provider name and must not replace it.
    assert "openrouter" in keys
    refute "open_router" in keys
    assert ProviderRegistry.known?("openrouter")
    refute ProviderRegistry.known?("open_router")

    for key <- keys do
      # ACP is discovered by ProviderCatalog from the CLI adapter, not
      # ReqLLM / local-LM registry entries.
      assert ProviderRegistry.known?(key) or key == "acp",
             "doctor catalog key #{inspect(key)} is not a known ProviderRegistry provider"
    end
  end
end
