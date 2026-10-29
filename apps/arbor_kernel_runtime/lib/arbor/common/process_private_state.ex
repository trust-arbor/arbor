defmodule Arbor.Common.ProcessPrivateState do
  @moduledoc """
  Compatibility entry points for process-owned private state.

  New consumers use `Arbor.Custody`. Existing anchors keep their exact sealed
  table identity and remain readable by the same owning process.
  """

  @type error :: {:error, :invalid_private_state}

  @doc "Creates one exact private value store for anchor in the calling process."
  @spec open(term(), atom(), term(), (term() -> boolean())) :: :ok | error()
  def open(anchor, schema, value, validator),
    do: Arbor.Custody.open_process_private_state(anchor, schema, value, validator)

  @doc "Reads the value from the exact private table sealed for anchor."
  @spec fetch(term(), atom(), (term() -> boolean())) :: {:ok, term()} | error()
  def fetch(anchor, schema, validator),
    do: Arbor.Custody.fetch_process_private_state(anchor, schema, validator)

  @doc "Replaces the sealed value after validating both old and new values."
  @spec replace(term(), atom(), term(), (term() -> boolean())) :: :ok | error()
  def replace(anchor, schema, value, validator),
    do: Arbor.Custody.replace_process_private_state(anchor, schema, value, validator)

  @doc "Updates the sealed value inside the owning process."
  @spec update(term(), atom(), (term() -> term()), (term() -> boolean())) :: :ok | error()
  def update(anchor, schema, update_fun, validator),
    do: Arbor.Custody.update_process_private_state(anchor, schema, update_fun, validator)

  @doc "Deletes the exact sealed table owned by the calling process."
  @spec close(term()) :: :ok
  def close(anchor), do: Arbor.Custody.close_process_private_state(anchor)
end
