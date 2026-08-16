defmodule Arbor.Commands.SafeRecoveryArtifact.CleanupReceipt do
  @moduledoc false

  @enforce_keys [:schema, :owner, :token]
  defstruct [:schema, :owner, :token]

  @type t :: %__MODULE__{schema: String.t(), owner: pid(), token: binary()}
end
