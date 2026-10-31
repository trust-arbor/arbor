defmodule HistorianStandaloneConsumer do
  @moduledoc "Public leaf-runtime proof; ordinary in-memory history is not node-restart audit authority."
  alias Arbor.Historian
  alias Arbor.Persistence.Core, as: Persistence
  alias Arbor.Persistence.EventLog.ETS
  @backend HistorianStandaloneConsumer.OrdinaryLog
  @first_party ~w(arbor_historian arbor_kernel arbor_persistence arbor_support)
  @owned_modules [
    Arbor.Historian,
    Arbor.Historian.Application,
    Arbor.Historian.AuthorityAuditPuller,
    Arbor.Historian.QueryEngine,
    Arbor.Historian.Event,
    Arbor.Historian.HistoryEntry,
    Arbor.Historian.StreamContent,
    Arbor.Historian.StreamContent.Core,
    Arbor.Historian.SecurityInvocationSink,
    Arbor.Historian.Timeline,
    Arbor.Historian.Timeline.Span,
    Arbor.Historian.Ports.Authorizer,
    Arbor.Historian.Ports.AuthoritySource
  ]
  @forbidden [
    Arbor.Security,
    Arbor.Custody,
    Arbor.Common,
    Arbor.KernelRuntime,
    Arbor.Signals,
    Arbor.Persistence,
    Arbor.Persistence.Repo,
    Arbor.Persistence.EventLog.Ecto,
    Arbor.Historian.Host,
    Arbor.Historian.TestAuditRuntime,
    Arbor.Historian.TestAuditRepo
  ]

  defmodule Observer do
    @moduledoc false
    @behaviour Arbor.Historian.Contracts.Authorizer
    @behaviour Arbor.Historian.Contracts.AuthoritySource
    def authorize(_, _, _, _), do: observe(:authorize, {:error, :consumer_not_authorized})

    def authorize_self_scoped(_, _, _, _, _, _),
      do: observe(:self_scoped, {:error, :consumer_not_authorized})

    def reconcile_authority_audit, do: observe(:reconcile, :ok)
    def authority_audit_delivery_batch, do: observe(:batch, {:ok, []})
    def acknowledge_authority_audit(_, _), do: observe(:acknowledge, {:error, :journal_not_bound})

    defp observe(operation, result) do
      {pid, reference} = Application.fetch_env!(:historian_standalone_consumer, :observer)
      send(pid, {reference, operation, self()})
      result
    end
  end

  defmodule Crashed do
    @moduledoc false
    def authorize(_, _, _, _), do: raise("private provider detail")
    def authorize_self_scoped(_, _, _, _, _, _), do: exit(:private_provider_detail)
    def reconcile_authority_audit, do: throw(:private_provider_detail)
    def authority_audit_delivery_batch, do: raise("private provider detail")
    def acknowledge_authority_audit(_, _), do: exit(:private_provider_detail)
  end

  defmodule Malformed do
    @moduledoc false
    def authorize(_, _, _, _), do: {:ok, true}
    def authorize_self_scoped(_, _, _, _, _, _), do: {:ok, :pending_approval, %{invalid: true}}
    def reconcile_authority_audit, do: {:ok, :wrong}
    def authority_audit_delivery_batch, do: {:ok, [nil]}
    def acknowledge_authority_audit(_, _), do: :ok
  end

  def verify!(opts \\ []) do
    if Keyword.get(opts, :require_no_mix, false) do
      ensure(not Code.ensure_loaded?(Mix), "Mix code present")
      ensure(:code.lib_dir(:mix) == {:error, :bad_name}, "Mix metadata present")
    end

    {:ok, _} = Application.ensure_all_started(:arbor_historian)
    assert_closure!()
    identity = canonical_identity!()
    ensure(is_nil(Process.whereis(@backend)), "ordinary backend is borrowed")

    {:ok, backend} =
      ETS.start_link(name: @backend, trim_interval_ms: :disabled, max_age_ms: :infinity)

    original =
      Map.new(
        [:authorizer, :authority_source, :durable_event_log_target, :hot_event_log_target],
        &{&1, Application.fetch_env(:arbor_historian, &1)}
      )

    try do
      Application.put_env(:arbor_historian, :durable_event_log_target, %{
        name: @backend,
        backend: ETS,
        opts: []
      })

      {:ok, :process_lifetime} = Persistence.durability_class(@backend, ETS, [])
      ordinary_history!()
      authority_refusals_and_ports!(identity.puller)
      legacy_topology!()
      final_identity = canonical_identity!()
      assert_closure!()

      paths =
        Map.new(@owned_modules, fn module ->
          ensure(Code.ensure_loaded?(module), "public module unavailable")

          ensure(
            :application.get_application(module) == {:ok, :arbor_historian},
            "wrong module owner"
          )

          {Atom.to_string(module), List.to_string(:code.which(module))}
        end)

      %{
        "package" => "arbor_historian",
        "version" => Application.spec(:arbor_historian, :vsn) |> List.to_string(),
        "check_groups" => 7,
        "checks" => [
          "canonical active application/direct-child/module ownership",
          "ordinary public append/read/query with actual ETS",
          "public timeline and summary",
          "exact stream delete/absence and reserved audit deletion refusal",
          "absent/down/malformed trusted providers fail closed",
          "inline caller and actual canonical puller PID callbacks without authority",
          "distinct legacy two-child facade topology and canonical restart"
        ],
        "storage_durability" => "process_lifetime",
        "node_restart_audit_qualified" => false,
        "composed_required" => [
          "real production Capabilities caller provenance",
          "real SQL node_restart readback/ACK",
          "lost ACK/conflict/outage",
          "whole BEAM restart and compatible-state rollback"
        ],
        "canonical_root_live" => Process.alive?(final_identity.supervisor),
        "canonical_puller_live" => Process.alive?(final_identity.puller),
        "code_paths" => paths,
        "compiled_applications" => compiled_apps(),
        "loaded_applications" => app_names(Application.loaded_applications()),
        "started_applications" => app_names(Application.started_applications()),
        "mix_available" => Code.ensure_loaded?(Mix)
      }
    after
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_historian, key, value)
        {key, :error} -> Application.delete_env(:arbor_historian, key)
      end)

      Application.delete_env(:historian_standalone_consumer, :observer)
      if Process.alive?(backend), do: GenServer.stop(backend, :normal)
    end
  end

  defp canonical_identity! do
    ensure(
      Application.spec(:arbor_historian, :mod) == {Arbor.Historian.Application, []},
      "canonical callback changed"
    )

    supervisor = Process.whereis(Arbor.Historian.Supervisor)
    ensure(is_pid(supervisor), "canonical supervisor absent")
    children = Supervisor.which_children(supervisor)

    expected =
      MapSet.new([ETS, Arbor.Historian.StreamRegistry, Arbor.Historian.AuthorityAuditPuller])

    ensure(
      MapSet.new(children, &elem(&1, 0)) == expected,
      "canonical direct-child topology changed"
    )

    {Arbor.Historian.AuthorityAuditPuller, puller, :worker, _} =
      List.keyfind(children, Arbor.Historian.AuthorityAuditPuller, 0)

    ensure(
      is_pid(puller) and puller == Process.whereis(Arbor.Historian.AuthorityAuditPuller),
      "puller is reparented"
    )

    ensure(
      :application.get_application(Arbor.Historian.Application) == {:ok, :arbor_historian},
      "wrong callback owner"
    )

    ensure(
      :application.get_application(Arbor.Historian.AuthorityAuditPuller) ==
        {:ok, :arbor_historian},
      "wrong puller owner"
    )

    %{supervisor: supervisor, puller: puller}
  end

  defp ordinary_history! do
    :ok =
      Historian.persist_durable_event("global", "activity:leaf_entry", %{value: 1},
        metadata: %{signal_id: "leaf_one", source: "arbor://leaf"},
        agent_id: "agent_leaf"
      )

    :ok =
      Historian.persist_durable_event("global", "activity:leaf_entry", %{value: 2},
        metadata: %{signal_id: "leaf_two", source: "arbor://leaf"},
        agent_id: "agent_leaf",
        cause_id: "leaf_one"
      )

    {:ok, raw} = Historian.read_durable_event_stream("global", limit: 10)
    ensure(length(raw) == 2, "ordinary persist/read did not round trip")

    ensure(
      Enum.map(raw, & &1.metadata["signal_id"]) == ["leaf_one", "leaf_two"],
      "signal metadata changed"
    )

    ensure(
      Enum.all?(
        raw,
        &(is_integer(&1.event_number) and &1.event_number > 0 and
            is_binary(&1.operation_fingerprint))
      ),
      "append acknowledgement lacked positions/fingerprint"
    )

    {:ok, recent} = Historian.recent(limit: 10)

    ensure(
      Enum.map(recent, & &1.signal_id) == ["leaf_one", "leaf_two"],
      "public history query changed"
    )

    {:ok, queried} = Historian.query(category: :activity, limit: 10, max_scan: 20)

    ensure(
      Enum.map(queried, & &1.signal_id) == ["leaf_one", "leaf_two"],
      "bounded category query changed"
    )

    first = hd(raw).timestamp
    last = List.last(raw).timestamp

    span =
      Historian.span(
        from: DateTime.add(first, -1, :second),
        to: DateTime.add(last, 1, :second),
        streams: ["global"]
      )

    {:ok, timeline} = Historian.reconstruct(span)

    ensure(
      Enum.map(timeline, & &1.signal_id) == ["leaf_one", "leaf_two"],
      "public timeline reconstruction changed"
    )

    ensure(Historian.timeline_summary(span).total == 2, "timeline summary changed")

    :ok =
      Historian.persist_durable_event("ordinary:delete", "activity:leaf_entry", %{value: 3}, [])

    :ok =
      Historian.persist_durable_event("ordinary:delete2", "activity:leaf_entry", %{value: 4}, [])

    {:ok, false} = Historian.stream_content_absent?("ordinary:delete", timeout_ms: 2_000)
    :ok = Historian.delete_stream_content("ordinary:delete", timeout_ms: 2_000)
    {:ok, true} = Historian.stream_content_absent?("ordinary:delete", timeout_ms: 2_000)
    {:ok, []} = Historian.read_durable_event_stream("ordinary:delete")
    {:ok, [survivor]} = Historian.read_durable_event_stream("ordinary:delete2")
    ensure(survivor.data["value"] == 4, "exact deletion changed a prefix-related stream")

    for stream <- ["security:authority_mutation:leaf", "security:invocation:leaf"] do
      ensure(
        Historian.delete_stream_content(stream) == {:error, :delete_not_supported},
        "audit stream deletion was admitted"
      )
    end
  end

  defp authority_refusals_and_ports!(puller) do
    for provider <- [nil, false, __MODULE__.Missing, Crashed] do
      Application.put_env(:arbor_historian, :authorizer, provider)
      Application.put_env(:arbor_historian, :authority_source, provider)

      ensure(
        Historian.authorize_query("agent_leaf", category: :security) ==
          {:error, {:unauthorized, :security_provider_unavailable}},
        "unavailable authorizer fell back"
      )

      ensure(
        Historian.flush_authority_audit() == {:error, :audit_source_unavailable},
        "unavailable source fell back"
      )
    end

    Application.put_env(:arbor_historian, :authorizer, Malformed)
    Application.put_env(:arbor_historian, :authority_source, Malformed)

    ensure(
      Historian.authorize_query("agent_leaf", category: :security) ==
        {:error, {:unauthorized, :invalid_authorization_reply}},
      "malformed authorizer succeeded"
    )

    ensure(
      Historian.flush_authority_audit() == {:error, :audit_source_unavailable},
      "malformed source succeeded"
    )

    ensure(
      Historian.security_audit_identity() == {:error, :invocation_audit_unavailable},
      "volatile target claimed node_restart identity"
    )

    ensure(
      Historian.security_invocation("inv_" <> String.duplicate("a", 32)) ==
        {:error, :invocation_audit_unavailable},
      "volatile target read acknowledged security evidence"
    )

    reference = make_ref()
    Application.put_env(:historian_standalone_consumer, :observer, {self(), reference})
    Application.put_env(:arbor_historian, :authorizer, Observer)
    Application.put_env(:arbor_historian, :authority_source, Observer)

    ensure(
      Historian.authorize_query("agent_leaf",
        stream: Arbor.Historian.StreamIds.for_agent("agent_leaf")
      ) ==
        {:error, {:unauthorized, :consumer_not_authorized}},
      "observer acquired authority"
    )

    expect_pid!(reference, :self_scoped, self())

    ensure(
      Historian.flush_authority_audit() == {:ok, %{delivered: 0, pending: 0}},
      "empty observer protocol failed"
    )

    expect_pid!(reference, :reconcile, puller)
    expect_pid!(reference, :batch, puller)
    Application.put_env(:arbor_historian, :authorizer, nil)
    Application.put_env(:arbor_historian, :authority_source, nil)
  end

  defp legacy_topology! do
    :ok = Application.stop(:arbor_historian)
    {:ok, legacy} = Historian.start_link([])

    try do
      ensure(
        MapSet.new(Supervisor.which_children(legacy), &elem(&1, 0)) ==
          MapSet.new([ETS, Arbor.Historian.StreamRegistry]),
        "legacy facade topology changed"
      )

      ensure(
        is_nil(Process.whereis(Arbor.Historian.AuthorityAuditPuller)),
        "legacy facade started an authority puller"
      )
    after
      Supervisor.stop(legacy, :normal)
      {:ok, _} = Application.ensure_all_started(:arbor_historian)
    end
  end

  defp expect_pid!(reference, operation, expected) do
    receive do
      {^reference, ^operation, ^expected} -> :ok
      {^reference, ^operation, _other} -> raise("Historian callback moved to another process")
    after
      2_000 -> raise("Historian callback was not observed")
    end
  end

  defp assert_closure! do
    for names <- [
          compiled_apps(),
          app_names(Application.loaded_applications()),
          app_names(Application.started_applications())
        ] do
      ensure(
        Enum.filter(names, &String.starts_with?(&1, "arbor_")) == @first_party,
        "first-party closure changed"
      )
    end

    for module <- @forbidden do
      ensure(not Code.ensure_loaded?(module), "ambient product/test module available")
    end

    for app <- [:arbor_kernel, :arbor_support, :arbor_persistence] do
      ensure(
        Application.spec(app, :mod) in [nil, []],
        "leaf dependency acquired an application callback"
      )
    end
  end

  defp compiled_apps do
    :code.get_path()
    |> Enum.flat_map(fn path -> Path.wildcard(Path.join(List.to_string(path), "arbor_*.app")) end)
    |> Enum.map(&Path.basename(&1, ".app"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp app_names(apps), do: apps |> Enum.map(&Atom.to_string(elem(&1, 0))) |> Enum.sort()
  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("Historian qualification failed: " <> label)
end
