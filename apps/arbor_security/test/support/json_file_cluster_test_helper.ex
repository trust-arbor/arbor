defmodule Arbor.Security.TestSupport.JSONFileClusterTestHelper do
  @moduledoc false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.Store.JSONFile

  @doc false
  def contend(parent, ready_ref, release_ref, key, opts, writer, payload_bytes)
      when is_pid(parent) and is_reference(ready_ref) and is_reference(release_ref) and
             is_binary(key) and is_list(opts) and is_binary(writer) and
             is_integer(payload_bytes) and payload_bytes > 0 do
    record =
      Record.new(key, %{
        "writer" => writer,
        "padding" => String.duplicate(writer, payload_bytes)
      })

    send(parent, {ready_ref, node(), self()})

    receive do
      {:release, ^release_ref} -> JSONFile.compare_and_swap(key, :not_found, record, opts)
    after
      30_000 -> {:error, :release_timeout}
    end
  end

  @doc false
  def get(key, opts), do: JSONFile.get(key, opts)
end
