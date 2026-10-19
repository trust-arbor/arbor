defmodule Arbor.Persistence.Ecto.NamedSchemaRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Ecto.EventLog
  alias Arbor.Persistence.Ecto.EventLogSchema
  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.Event

  @trigger "arbor_event_log_operation_fence_insert"
  @function "arbor_event_log_enforce_operation_fence"

  describe "operation_trigger_definition?/2" do
    test "security regression: admits both PostgreSQL renderings of the fence trigger only" do
      schema = "arbor_named"

      # Schema off search_path: PostgreSQL qualifies the function.
      assert EventLogSchema.operation_trigger_definition?(
               trigger_definition(schema, "#{schema}.#{@function}"),
               schema
             )

      # Schema on search_path (e.g. public): the function is unqualified.
      assert EventLogSchema.operation_trigger_definition?(
               trigger_definition("public", @function),
               "public"
             )

      refute EventLogSchema.operation_trigger_definition?(
               trigger_definition(schema, "other_schema.#{@function}"),
               schema
             )

      refute EventLogSchema.operation_trigger_definition?(
               trigger_definition(schema, "#{schema}.substituted_fence"),
               schema
             )

      refute EventLogSchema.operation_trigger_definition?(
               trigger_definition("other_schema", "#{schema}.#{@function}"),
               schema
             )

      refute EventLogSchema.operation_trigger_definition?(
               "CREATE TRIGGER #{@trigger} AFTER INSERT ON #{schema}.events " <>
                 "FOR EACH ROW EXECUTE FUNCTION #{schema}.#{@function}()",
               schema
             )
    end
  end

  describe "named EventStore schema" do
    @describetag :database
    @describetag :integration

    test "security regression: exact named-schema trigger is admitted but a substituted body is denied" do
      previous = Application.get_env(:arbor_persistence_ecto, Store)
      schema = "persistence_named_#{System.unique_integer([:positive])}"
      Application.put_env(:arbor_persistence_ecto, Store, event_store_config(schema))

      config = Store.config()
      connection_opts = EventStore.Config.default_postgrex_opts(config)

      on_exit(fn ->
        if previous do
          Application.put_env(:arbor_persistence_ecto, Store, previous)
        else
          Application.delete_env(:arbor_persistence_ecto, Store)
        end

        {:ok, cleanup} = Postgrex.start_link(connection_opts)

        Postgrex.query!(
          cleanup,
          "DROP SCHEMA IF EXISTS #{EventLogSchema.quote_identifier(schema)} CASCADE",
          []
        )

        GenServer.stop(cleanup)
      end)

      conn = start_supervised!({Postgrex, connection_opts})
      Postgrex.query!(conn, "CREATE SCHEMA #{EventLogSchema.quote_identifier(schema)}", [])
      :ok = EventStore.Tasks.Init.exec(config, quiet: true)

      # Migration ends with verify/3, so this fails if the qualified
      # pg_get_triggerdef rendering of the named schema's fence is rejected.
      assert :ok = EventLogSchema.migrate!(conn, schema)
      start_supervised!(Store)

      event = Event.new("named-schema", "arbor.review.ordinary", %{value: 1})
      assert {:ok, [%Event{} = committed]} = EventLog.append("named-schema", event)
      assert committed.id == event.id

      Postgrex.query!(
        conn,
        """
        CREATE OR REPLACE FUNCTION #{EventLogSchema.quote_identifier(schema)}.#{@function}()
        RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$
        """,
        []
      )

      assert {:error, {:event_log_schema_unavailable, :operation_trigger_invalid}} =
               EventLog.append(
                 "named-schema",
                 Event.new("named-schema", "arbor.review.tampered", %{})
               )

      assert {:ok, [%Event{id: committed_id}]} = EventLog.read_stream("named-schema")
      assert committed_id == event.id
    end
  end

  defp trigger_definition(schema, function_name) do
    "CREATE TRIGGER #{@trigger} BEFORE INSERT ON #{schema}.events " <>
      "FOR EACH ROW EXECUTE FUNCTION #{function_name}()"
  end

  defp event_store_config(schema) do
    [
      serializer: EventStore.JsonSerializer,
      username: System.get_env("POSTGRES_USER", "arbor_dev"),
      password: System.get_env("POSTGRES_PASSWORD", ""),
      database: System.get_env("POSTGRES_DB", "trust_arbor_test"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      prepare: :unnamed,
      pool_size: 2,
      schema: schema
    ]
  end
end
