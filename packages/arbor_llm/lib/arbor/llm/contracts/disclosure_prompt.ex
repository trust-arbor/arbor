defmodule Arbor.LLM.Contracts.DisclosurePrompt do
  @moduledoc """
  Trusted host interaction for an explicit OpenCode disclosure acknowledgement.

  The host displays the library's exact disclosure text and asks its exact
  question. Missing or unavailable providers leave disclosure unacknowledged;
  the library supplies no implicit Mix or IO implementation.
  """

  @callback info(String.t()) :: :ok
  @callback yes?(String.t()) :: boolean()
end
