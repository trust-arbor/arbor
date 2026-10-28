defmodule Arbor.Persistence.Schemas.EventLogOperation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:operation_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "event_log_operations" do
    field(:stream_id, :string)
    field(:identity, :map)
    field(:status, :string)
    field(:reason, :string)

    timestamps()
  end
end
