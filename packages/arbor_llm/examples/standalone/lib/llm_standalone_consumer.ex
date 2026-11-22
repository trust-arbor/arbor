defmodule LLMStandaloneConsumer do
  @moduledoc "Public LLM qualification with a caller-owned local wire and explicit bounded ports."

  alias Arbor.Contracts.Security.Taint
  alias Arbor.LLM
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.{Client, Message, Request, StreamEvent, ToolLoop}
  alias LLMStandaloneConsumer.{Auditor, Executor, Policy, Ports, Wire}

  @first_party ["arbor_kernel", "arbor_llm", "arbor_oauth", "arbor_signals", "arbor_support"]
  @started ["arbor_kernel", "arbor_llm", "arbor_oauth", "arbor_support"]
  @env_keys [
    :sensitivity_policy,
    :sensitivity_classifier,
    :tool_invocation_auditor,
    :tool_executor,
    :signal_module,
    :telemetry_store,
    :external_provider_adapters,
    :trusted_proxy_endpoints,
    :lm_studio,
    :oauth_store_dir,
    :oauth_source_files,
    :opencode_zen_acknowledgement_path
  ]
  @owners [
    {Arbor, :arbor_llm},
    {Arbor.LLM, :arbor_llm},
    {Arbor.AI.LLMError, :arbor_llm},
    {Arbor.Orchestrator.ToolHooks, :arbor_llm},
    {Arbor.Eval.Subject, :arbor_kernel},
    {Taint, :arbor_kernel},
    {Arbor.Common.SensitivityClassifier, :arbor_support},
    {Arbor.Common.SafePath.NativeReaderArtifact, :arbor_support},
    {Arbor.Common.OAuth.HttpClient, :arbor_oauth},
    {Arbor.Signals.Taint, :arbor_signals}
  ]

  def run!(opts \\ []) do
    require_no_mix = Keyword.get(opts, :require_no_mix, false)
    ensure(require_no_mix in [true, false], "invalid no-Mix requirement")
    if require_no_mix, do: no_mix!()
    root = private_root!()
    previous = Map.new(@env_keys, &{&1, Application.fetch_env(:arbor_llm, &1)})
    previous_context = Application.fetch_env(:llm_standalone_consumer, :context)
    {:ok, context} = Agent.start(fn -> %{origin: nil, audits: 0, effects: 0} end)

    try do
      Application.put_env(:llm_standalone_consumer, :context, context)
      configure(root)
      {:ok, _} = Application.ensure_all_started(:arbor_llm)
      load_signals_metadata!()
      closure!()
      module_owners = owners!()
      topology!()
      resources = resources!()
      client = Client.new(adapters: %{"lm_studio" => Adapter}, default_provider: "lm_studio")
      facade_groups!(client)
      tool_groups!(client, root)
      refusals!(client, root)
      abort!(client)
      lifecycle!()
      closure!()
      if require_no_mix, do: release_paths!()

      %{
        "schema" => "arbor.llm.standalone-consumer.v1",
        "checks" => [
          "generate_http",
          "stream_sse",
          "generate_object_http",
          "stream_object_sse",
          "indexed_embedding_http",
          "fragmented_tool_call",
          "audited_tool_effect",
          "missing_policy_no_http",
          "finite_policy_denial_no_http",
          "unknown_route_no_http",
          "private_selection_no_http",
          "missing_executor_no_http",
          "missing_auditor_no_tool_effect",
          "early_stream_halt",
          "canonical_oauth_tree",
          "llm_stop_restart",
          "bundled_resources"
        ],
        "facade_groups" => 5,
        "tool_effects" => 1,
        "audited_effects" => 1,
        "required_port_refusal_groups" => 3,
        "early_stream_halt_closed_wire" => true,
        "oauth_scope" => "actual canonical tree and no premature listener; no deep login proof",
        "compiled_applications" => compiled_apps(),
        "loaded_applications" => first_party(Application.loaded_applications()),
        "started_applications" => first_party(Application.started_applications()),
        "code_paths" =>
          Enum.map(module_owners, fn {_module, value} -> value.beam end) |> Enum.sort(),
        "module_owners" => module_owners,
        "bundled_resources" => resources,
        "mix_available" => Code.ensure_loaded?(Mix)
      }
    after
      Enum.each(previous, fn {key, value} -> restore(:arbor_llm, key, value) end)
      restore(:llm_standalone_consumer, :context, previous_context)
      Agent.stop(context)
    end
  end

  defp configure(root) do
    oauth = Path.join(root, "oauth")
    File.mkdir_p!(oauth)
    File.chmod!(oauth, 0o700)
    {:ok, ^oauth} = Arbor.Common.SafePath.resolve_real(oauth)
    ensure(File.ls!(oauth) == [], "OAuth store must be private and empty")
    Application.put_env(:arbor_llm, :oauth_store_dir, oauth)

    Application.put_env(:arbor_llm, :oauth_source_files, %{
      openai: Path.join(root, "absent-openai-source.json")
    })

    Application.put_env(
      :arbor_llm,
      :opencode_zen_acknowledgement_path,
      Path.join(root, "ack.json")
    )

    Application.put_env(:arbor_llm, :sensitivity_policy, Policy)
    Application.put_env(:arbor_llm, :sensitivity_classifier, Arbor.Common.SensitivityClassifier)
    Application.put_env(:arbor_llm, :tool_invocation_auditor, Auditor)
    Application.put_env(:arbor_llm, :tool_executor, Executor)
    Application.put_env(:arbor_llm, :signal_module, nil)
    Application.put_env(:arbor_llm, :telemetry_store, nil)
    Application.put_env(:arbor_llm, :external_provider_adapters, %{})
  end

  defp facade_groups!(client) do
    with_wire(
      [%{json: completion("hello")}],
      fn url ->
        {:ok, response} = LLM.generate(options(url, "cold-chat"))
        ensure(response.text == "hello", "generate response changed")

        ensure(
          response.usage.input_tokens == 3 and response.usage.output_tokens == 2,
          "generate usage changed"
        )
      end,
      1,
      "/v1/chat/completions",
      "cold-chat"
    )

    with_wire(
      [%{chunks: text_chunks(["hello"])}],
      fn url ->
        {:ok, stream} = LLM.stream(options(url, "cold-chat", client: client))
        events = Enum.to_list(stream)

        ensure(
          Enum.any?(events, &match?(%StreamEvent{type: :delta, data: %{text: "hello"}}, &1)),
          "stream text missing"
        )

        ensure(
          not Enum.any?(events, &match?(%StreamEvent{type: :error}, &1)),
          "stream returned an error"
        )
      end,
      1,
      "/v1/chat/completions",
      "cold-chat"
    )

    with_wire(
      [%{json: completion("{\"ok\":true}", "cold-object")}],
      fn url ->
        {:ok, %{"ok" => true}} =
          LLM.generate_object(
            options(url, "cold-object", client: client, schema: object_schema())
          )
      end,
      1,
      "/v1/chat/completions",
      "cold-object"
    )

    with_wire(
      [%{chunks: text_chunks(["{\"ok\":", "true}"])}],
      fn url ->
        {:ok, stream} =
          LLM.stream_object(options(url, "cold-object", client: client, schema: object_schema()))

        ensure(
          List.last(Enum.to_list(stream)) == %{"ok" => true},
          "stream_object final value changed"
        )
      end,
      1,
      "/v1/chat/completions",
      "cold-object"
    )

    body = %{
      "object" => "list",
      "model" => "cold-embed",
      "data" => [
        %{"object" => "embedding", "index" => 0, "embedding" => [1.0, 0.0]},
        %{"object" => "embedding", "index" => 1, "embedding" => [0.0, 1.0]}
      ],
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }

    report =
      with_wire(
        [%{json: body}],
        fn url ->
          {:ok, result} =
            LLM.embed_batch("lm_studio", "cold-embed", ["first", "second"], transport(url))

          ensure(result.association_version == 1, "embedding association version changed")
          ensure(result.embeddings == [[1.0, 0.0], [0.0, 1.0]], "embedding association changed")

          ensure(
            Enum.map(result.indexed_embeddings, & &1.index) == [0, 1],
            "embedding indices changed"
          )
        end,
        1,
        "/v1/embeddings",
        "cold-embed"
      )

    ensure(
      hd(report.captures).body["input"] == ["first", "second"],
      "embedding input order changed"
    )
  end

  defp tool_groups!(client, root) do
    Ports.reset()

    report =
      with_wire(
        tool_responses(),
        fn url ->
          taint = public_taint!()
          {:ok, result} = ToolLoop.run(client, tool_request(), tool_options(url, root, taint))
          ensure(result.content == "done", "tool loop did not complete")
          ensure(result.taint == taint, "tool taint carry changed")

          ensure(
            Ports.counts() == %{audits: 1, effects: 1},
            "one audited tool effect was not observed"
          )
        end,
        2,
        "/v1/chat/completions",
        "cold-tool"
      )

    content = report.captures |> List.last() |> Map.fetch!(:body) |> Map.fetch!("messages")

    ensure(
      Enum.any?(content, &(&1["role"] == "tool" and String.contains?(&1["content"], "2"))),
      "tool result did not reach wire"
    )
  end

  defp refusals!(client, root) do
    with_wire(
      [%{json: completion("forbidden")}],
      fn url ->
        Application.put_env(:arbor_llm, :sensitivity_policy, nil)

        ensure(
          match?(
            {:error, {:sensitivity_blocked, :policy_unavailable}},
            LLM.generate(options(url, "cold-chat"))
          ),
          "missing policy did not deny"
        )

        Application.put_env(:arbor_llm, :sensitivity_policy, Policy)
      end,
      0,
      "/v1/chat/completions",
      "cold-chat"
    )

    with_wire(
      [%{json: completion("forbidden")}],
      fn url ->
        ensure(
          match?(
            {:error, {:sensitivity_blocked, :destination_disallowed}},
            LLM.generate(options(url, "not-admitted"))
          ),
          "finite policy did not deny"
        )

        ensure(
          match?(
            {:error, :live_completion_provider_unsupported},
            LLM.generate(options(url, "cold-chat", provider: "unregistered-route"))
          ),
          "unknown route did not deny"
        )

        ensure(
          match?(
            {:error, :live_completion_configuration_unsupported},
            LLM.generate(
              options(url, "cold-chat", client_opts: [eval_fixture_set: "unpublished"])
            )
          ),
          "private fixture selection did not deny"
        )
      end,
      0,
      "/v1/chat/completions",
      "cold-chat"
    )

    with_wire(
      [%{json: completion("forbidden")}],
      fn url ->
        taint = public_taint!()
        opts = tool_options(url, root, taint) |> Keyword.put(:tool_executor, nil)

        ensure(
          ToolLoop.run(client, tool_request(), opts) == {:error, :tool_executor_unavailable},
          "missing executor did not deny"
        )
      end,
      0,
      "/v1/chat/completions",
      "cold-tool"
    )

    Ports.reset()
    Application.put_env(:arbor_llm, :tool_invocation_auditor, nil)

    report =
      with_wire(
        tool_responses(),
        fn url ->
          taint = public_taint!()
          {:ok, _} = ToolLoop.run(client, tool_request(), tool_options(url, root, taint))

          ensure(
            Ports.counts() == %{audits: 0, effects: 0},
            "missing auditor reached tool effect"
          )
        end,
        2,
        "/v1/chat/completions",
        "cold-tool"
      )

    messages = report.captures |> List.last() |> Map.fetch!(:body) |> Map.fetch!("messages")

    ensure(
      Enum.any?(
        messages,
        &(&1["role"] == "tool" and String.contains?(&1["content"], "invocation_audit_unavailable"))
      ),
      "audit refusal was not carried as tool result"
    )

    Application.put_env(:arbor_llm, :tool_invocation_auditor, Auditor)
  end

  defp abort!(client) do
    chunks =
      List.duplicate(
        sse(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "early"}}]}),
        200
      )

    report =
      with_wire(
        [%{chunks: chunks, delay_ms: 5}],
        fn url ->
          {:ok, stream} = LLM.stream(options(url, "cold-chat", client: client))

          seen =
            Enum.reduce_while(stream, false, fn
              %StreamEvent{type: :delta, data: %{text: "early"}}, _ -> {:halt, true}
              _, state -> {:cont, state}
            end)

          ensure(seen, "early stream delta missing")
        end,
        1,
        "/v1/chat/completions",
        "cold-chat"
      )

    captured = hd(report.captures)

    ensure(
      captured.peer_closed and captured.sent_chunks < length(chunks),
      "early halt did not close real TCP stream"
    )
  end

  defp with_wire(responses, fun, count, path, model) do
    wire = Wire.start(responses)

    try do
      Ports.allow(wire.url)
      Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{"lm_studio" => [wire.url]})
      Application.put_env(:arbor_llm, :lm_studio, base_url: wire.url)
      fun.(wire.url)
      report = Wire.finish(wire)
      ensure(Map.get(report, :error) == nil, "wire fixture failed")

      ensure(
        length(report.captures) == count and report.extra_connections == 0,
        "unexpected HTTP connection count"
      )

      for capture <- report.captures do
        ensure(capture.method == "POST" and capture.path == path, "HTTP method or path changed")
        ensure(capture.body["model"] == model, "HTTP model changed")
      end

      report
    after
      Wire.stop(wire)
    end
  end

  defp options(url, model, extra \\ []) do
    Keyword.merge(
      [
        provider: "lm_studio",
        model: model,
        prompt: "public synthetic input",
        timeout_ms: 2_000,
        max_response_bytes: 65_536,
        require_live_pipeline: not Keyword.has_key?(extra, :client),
        client_opts: transport(url)
      ],
      extra
    )
    |> then(fn opts ->
      if Keyword.has_key?(extra, :client),
        do: Keyword.delete(opts, :require_live_pipeline),
        else: opts
    end)
  end

  defp transport(url), do: [base_url: url, api_key: "cold-fixture-canary", receive_timeout: 2_000]

  defp tool_request do
    %Request{
      provider: "lm_studio",
      model: "cold-tool",
      messages: [Message.new(:user, "use the declared tool")]
    }
  end

  defp tool_options(url, root, taint) do
    transport(url) ++
      [
        tools: [
          %{
            "type" => "function",
            "function" => %{
              "name" => "cold_increment",
              "description" => "increment one synthetic value",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"value" => %{"type" => "integer"}},
                "required" => ["value"]
              }
            }
          }
        ],
        tool_executor: Executor,
        workdir: root,
        max_turns: 3,
        agent_id: "system",
        task_id: "cold_task",
        session_id: "cold_session",
        tool_taint: taint,
        stream_callback: fn _event -> :ok end,
        llm_call_authorizer: fn request, carried ->
          if request.provider == "lm_studio" and request.model == "cold-tool" and
               carried.sensitivity == :public, do: :allow, else: {:deny, :consumer_scope}
        end
      ]
  end

  defp completion(text, model \\ "cold-chat") do
    %{
      "id" => "cold-response",
      "object" => "chat.completion",
      "created" => 1,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    }
  end

  defp object_schema,
    do: %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

  defp text_chunks(texts) do
    Enum.map(
      texts,
      &sse(%{
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => &1}}]
      })
    ) ++
      [
        sse(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
        }),
        "data: [DONE]\n\n"
      ]
  end

  defp tool_responses do
    deltas = [
      %{
        "index" => 0,
        "id" => "cold_call_1",
        "type" => "function",
        "function" => %{"name" => "cold_increment", "arguments" => "{\""}
      },
      %{"index" => 0, "function" => %{"arguments" => "value\":1}"}}
    ]

    tool_chunks =
      Enum.map(
        deltas,
        &sse(%{"choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [&1]}}]})
      )

    finish =
      sse(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]})

    [%{chunks: tool_chunks ++ [finish, "data: [DONE]\n\n"]}, %{chunks: text_chunks(["done"])}]
  end

  defp sse(value), do: "data: " <> JSON.encode!(value) <> "\n\n"

  defp public_taint! do
    {:ok, taint} =
      Taint.new(%{
        level: :untrusted,
        sensitivity: :public,
        sanitizations: 0,
        confidence: :unverified,
        source: "consumer",
        chain: []
      })

    taint
  end

  defp private_root! do
    root = System.fetch_env!("LLM_COLD_STATE_ROOT")
    ensure(Path.type(root) == :absolute, "private root must be absolute")
    ensure(Path.expand(root) == root, "private root must be canonical")
    {:ok, ^root} = Arbor.Common.SafePath.resolve_real(root)
    {:ok, %{type: :directory, mode: mode}} = File.lstat(root)
    ensure(Bitwise.band(mode, 0o777) == 0o700, "private root must be mode0700")
    root
  end

  defp load_signals_metadata! do
    case Application.load(:arbor_signals) do
      :ok -> :ok
      {:error, {:already_loaded, :arbor_signals}} -> :ok
    end
  end

  defp closure! do
    ensure(compiled_apps() == @first_party, "first-party compiled closure changed")

    ensure(
      first_party(Application.loaded_applications()) == @first_party,
      "first-party loaded closure changed"
    )

    ensure(
      first_party(Application.started_applications()) == @started,
      "first-party started closure changed"
    )

    for app <- [:arbor_kernel, :arbor_support, :arbor_oauth] do
      ensure(Application.spec(app, :mod) in [nil, []], "passive application has callback")

      ensure(
        Application.spec(app, :registered) in [nil, []],
        "passive application declares names"
      )
    end

    ensure(Process.whereis(Arbor.Signals.Supervisor) == nil, "Signals started implicitly")

    for module <- [
          Arbor.Common,
          Arbor.KernelRuntime,
          Arbor.Security,
          Arbor.AI,
          Arbor.Orchestrator,
          Arbor.Commands,
          Arbor.Trust,
          Arbor.Historian
        ] do
      ensure(not Code.ensure_loaded?(module), "product module was available")
    end
  end

  defp owners! do
    Map.new(@owners, fn {module, owner} ->
      ensure(Code.ensure_loaded?(module), "required public module unavailable")
      ensure(Application.get_application(module) == owner, "public module owner changed")

      {Atom.to_string(module),
       %{application: Atom.to_string(owner), beam: List.to_string(:code.which(module))}}
    end)
  end

  defp topology! do
    ensure(
      Application.spec(:arbor_llm, :mod) == {Arbor.LLM.Application, []},
      "LLM callback changed"
    )

    supervisor = Process.whereis(Arbor.LLM.Supervisor)

    ensure(
      is_pid(supervisor) and :application.get_application(supervisor) == {:ok, :arbor_llm},
      "LLM supervisor provenance changed"
    )

    children = Supervisor.which_children(supervisor)

    for module <- [
          Arbor.LLM.OAuth.Login.PendingStore,
          Arbor.LLM.OAuth.RecoveryProofStore,
          Arbor.LLM.OAuth.Login.LoopbackRootSupervisor
        ] do
      {^module, pid, _type, [^module]} = List.keyfind(children, module, 0)
      ensure(is_pid(pid) and Process.whereis(module) == pid, "LLM child PID changed ownership")

      ensure(
        :application.get_application(pid) == {:ok, :arbor_llm},
        "LLM child application provenance changed"
      )
    end

    loopback_children = Supervisor.which_children(Arbor.LLM.OAuth.Login.LoopbackRootSupervisor)

    for module <- [
          Arbor.LLM.OAuth.Login.LoopbackRegistryOwner,
          Arbor.LLM.OAuth.Login.LoopbackSupervisor
        ] do
      {^module, pid, _type, [^module]} = List.keyfind(loopback_children, module, 0)

      ensure(
        is_pid(pid) and :application.get_application(pid) == {:ok, :arbor_llm},
        "loopback child provenance changed"
      )

      if module == Arbor.LLM.OAuth.Login.LoopbackSupervisor,
        do: ensure(Process.whereis(module) == pid, "loopback supervisor registration changed")
    end

    registry = Process.whereis(Arbor.LLM.OAuth.Login.LoopbackRegistry)

    ensure(
      is_pid(registry) and :application.get_application(registry) == {:ok, :arbor_llm},
      "loopback registry provenance changed"
    )

    ensure(
      DynamicSupervisor.which_children(Arbor.LLM.OAuth.Login.LoopbackSupervisor) == [],
      "loopback listener started before explicit login"
    )
  end

  defp resources! do
    admission =
      Application.app_dir(:arbor_llm, "priv/opencode_zen/admission.json") |> File.read!()

    ensure(is_list(JSON.decode!(admission)["models"]), "admission resource missing")

    snapshot =
      :code.priv_dir(:llm_db)
      |> List.to_string()
      |> Path.join("llm_db/snapshot.json")
      |> File.read!()

    ensure(byte_size(snapshot) > 0, "LLMDB bundled snapshot missing")

    %{
      "opencode_admission_sha256" => digest(admission),
      "llmdb_snapshot_sha256" => digest(snapshot)
    }
  end

  defp lifecycle! do
    old = Process.whereis(Arbor.LLM.Supervisor)
    :ok = Application.stop(:arbor_llm)
    ensure(not Process.alive?(old), "LLM supervisor survived stop")
    {:ok, _} = Application.ensure_all_started(:arbor_llm)
    ensure(Process.whereis(Arbor.LLM.Supervisor) != old, "LLM did not restart")
    topology!()
  end

  defp no_mix! do
    ensure(not Code.ensure_loaded?(Mix), "Mix code was available")
    ensure(:code.lib_dir(:mix) == {:error, :bad_name}, "Mix metadata was available")
  end

  defp release_paths! do
    root = :code.root_dir() |> List.to_string() |> Path.expand()

    ensure(
      Enum.all?(
        :code.get_path(),
        &String.starts_with?(Path.expand(List.to_string(&1)) <> "/", root <> "/")
      ),
      "non-release code path"
    )
  end

  defp first_party(apps),
    do:
      apps
      |> Enum.map(&(&1 |> elem(0) |> Atom.to_string()))
      |> Enum.filter(&String.starts_with?(&1, "arbor_"))
      |> Enum.sort()

  defp compiled_apps,
    do:
      :code.get_path()
      |> Enum.map(&Path.basename(Path.dirname(List.to_string(&1))))
      |> Enum.filter(&String.starts_with?(&1, "arbor_"))
      |> Enum.map(&String.replace(&1, ~r/-\d.*$/, ""))
      |> Enum.uniq()
      |> Enum.sort()

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("LLM qualification failed: " <> label)
end
