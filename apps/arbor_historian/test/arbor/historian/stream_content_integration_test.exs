defmodule Arbor.Historian.StreamContentIntegrationTest do
  @moduledoc """
  Real dual-store integration for complete-history stream content (VP-05D2C3I0C4C).

  Durable = EventLog.Ecto via Arbor.Persistence.Repo.
  Hot = EventLog.ETS named store.

  Supported adapter lanes must bind **ARBOR_DB** (config selects the adapter)
  and use **distinct absolute MIX_BUILD_PATH roots** so SQLite and PostgreSQL
  never share beam/priv artifacts. Never use `--no-validate-compile-env`.

      # SQLite lane
      ARBOR_DB=sqlite \\
      MIX_DEPS_PATH=<abs canonical deps> \\
      MIX_BUILD_PATH=/private/tmp/arbor-vp05d2c3i0c4c-sqlite-build \\
        ./bin/mix test --only database \\
        apps/arbor_historian/test/arbor/historian/stream_content_integration_test.exs

      # PostgreSQL lane
      ARBOR_DB=postgres \\
      MIX_DEPS_PATH=<abs canonical deps> \\
      MIX_BUILD_PATH=/private/tmp/arbor-vp05d2c3i0c4c-postgres-build \\
        ./bin/mix test --only database \\
        apps/arbor_historian/test/arbor/historian/stream_content_integration_test.exs
  """
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Historian
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Persistence.Repo

  @moduletag :integration
  @moduletag :database
  @moduletag spec: "VP-05D2C3I0C4C"

  setup do
    hot_name = :"c4c_integ_hot_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ETS, name: hot_name, mode: :projection, max_age_ms: :infinity, trim_interval_ms: :disabled}
    )

    previous_durable = Application.get_env(:arbor_historian, :durable_event_log_target)
    previous_hot = Application.get_env(:arbor_historian, :hot_event_log_target)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: :historian_durable_event_log,
      backend: EctoEventLog,
      opts: [repo: Repo]
    })

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: hot_name,
      backend: ETS,
      opts: []
    })

    on_exit(fn ->
      restore_env(:durable_event_log_target, previous_durable)
      restore_env(:hot_event_log_target, previous_hot)
    end)

    adapter = Repo.__adapter__()

    adapter_tag =
      Map.get(
        %{
          Ecto.Adapters.SQLite3 => :sqlite,
          Ecto.Adapters.Postgres => :postgres
        },
        adapter,
        :unknown_adapter
      )

    {:ok, hot_name: hot_name, adapter: adapter, adapter_tag: adapter_tag}
  end

  test "exact target delete on real durable Ecto + hot ETS preserves survivors", %{
    hot_name: hot_name,
    adapter: adapter,
    adapter_tag: adapter_tag
  } do
    # Concrete adapter receipt for the running lane (not a soft membership check alone).
    assert adapter in [Ecto.Adapters.SQLite3, Ecto.Adapters.Postgres]
    assert adapter_tag in [:sqlite, :postgres]
    assert Repo.__adapter__() == adapter

    target = "agent:alice"
    prefix_related = "agent:alice2"
    unrelated = "session:other"
    durable_name = :historian_durable_event_log

    durable_receipts =
      for stream <- [target, prefix_related, unrelated] do
        event =
          Event.new(stream, "integ.created", %{
            "stream" => stream,
            "lane" => Atom.to_string(adapter_tag)
          })

        assert {:ok, [persisted]} =
                 Persistence.append(durable_name, EctoEventLog, stream, event, repo: Repo)

        assert is_binary(persisted.id)
        assert is_integer(persisted.global_position)
        assert persisted.stream_id == stream

        assert {:ok, %{projected: 1, skipped: 0}} =
                 Persistence.project_committed_events(hot_name, ETS, [persisted])

        {stream, persisted}
      end

    {_target_stream, _target_d} = List.keyfind(durable_receipts, target, 0)
    {_prefix_stream, prefix_d} = List.keyfind(durable_receipts, prefix_related, 0)
    {_unrelated_stream, unrelated_d} = List.keyfind(durable_receipts, unrelated, 0)

    assert {:ok, [prefix_d_read]} =
             Persistence.read_stream(durable_name, EctoEventLog, prefix_related, repo: Repo)

    assert {:ok, [unrelated_d_read]} =
             Persistence.read_stream(durable_name, EctoEventLog, unrelated, repo: Repo)

    assert prefix_d_read.id == prefix_d.id
    assert prefix_d_read.global_position == prefix_d.global_position
    assert unrelated_d_read.id == unrelated_d.id
    assert unrelated_d_read.global_position == unrelated_d.global_position

    assert {:ok, [prefix_h]} = Persistence.read_stream(hot_name, ETS, prefix_related)
    assert {:ok, [unrelated_h]} = Persistence.read_stream(hot_name, ETS, unrelated)

    assert {:ok, false} = Historian.stream_content_absent?(target, timeout_ms: 10_000)
    assert :ok = Historian.delete_stream_content(target, timeout_ms: 10_000)
    assert {:ok, true} = Historian.stream_content_absent?(target, timeout_ms: 10_000)
    assert :ok = Historian.delete_stream_content(target, timeout_ms: 10_000)

    # Real Ecto absence receipt (not inject backend).
    assert {:ok, true} =
             Persistence.event_stream_absent?(durable_name, EctoEventLog, target, repo: Repo)

    assert {:ok, []} = Persistence.read_stream(hot_name, ETS, target)

    assert {:ok, [prefix_d_after]} =
             Persistence.read_stream(durable_name, EctoEventLog, prefix_related, repo: Repo)

    assert {:ok, [unrelated_d_after]} =
             Persistence.read_stream(durable_name, EctoEventLog, unrelated, repo: Repo)

    assert {:ok, [prefix_h_after]} = Persistence.read_stream(hot_name, ETS, prefix_related)
    assert {:ok, [unrelated_h_after]} = Persistence.read_stream(hot_name, ETS, unrelated)

    assert prefix_d_after.id == prefix_d.id
    assert prefix_d_after.global_position == prefix_d.global_position
    assert unrelated_d_after.id == unrelated_d.id
    assert unrelated_d_after.global_position == unrelated_d.global_position
    assert prefix_h_after.id == prefix_h.id
    assert prefix_h_after.global_position == prefix_h.global_position
    assert unrelated_h_after.id == unrelated_h.id
    assert unrelated_h_after.global_position == unrelated_h.global_position
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_historian, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_historian, key, value)
end
