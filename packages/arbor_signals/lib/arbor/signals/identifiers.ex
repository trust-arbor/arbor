defmodule Arbor.Signals.Identifiers do
  @moduledoc false

  @spec generate_id(String.t()) :: String.t()
  def generate_id(prefix) when is_binary(prefix) do
    prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
