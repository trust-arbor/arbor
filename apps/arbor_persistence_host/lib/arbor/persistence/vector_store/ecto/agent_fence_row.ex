defmodule Arbor.Persistence.VectorStore.Ecto.AgentFenceRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:agent_id, :string, autogenerate: false}

  schema "vector_agent_fences" do
    field(:state, :string)
    field(:closed_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end
end
