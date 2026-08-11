defmodule Arbor.Common.SkillLibraryHybridSearchTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SkillLibrary
  alias Arbor.Common.SkillLibrary.EmbeddingText
  alias Arbor.Contracts.Skill

  defmodule SuccessEmbed do
    @behaviour Arbor.Contracts.API.Embedding

    @impl true
    def embed(text, opts) do
      Process.put({__MODULE__, :last_opts}, opts)
      dims = Keyword.get(opts, :dimensions, 768)
      # Deterministic unit-ish vector from text length for tests (not a product fallback).
      seed = :erlang.phash2(text, 10_000)

      embedding =
        for i <- 0..(dims - 1) do
          :math.sin((seed + i) / 100) * 0.01
        end

      {:ok,
       %{
         embedding: embedding,
         model: "test-model",
         provider: :test,
         usage: %{prompt_tokens: 0, total_tokens: 0},
         dimensions: dims
       }}
    end

    def last_opts, do: Process.get({__MODULE__, :last_opts})

    @impl true
    def embed_batch(texts, opts), do: {:ok, batch_from_single(texts, opts)}

    defp batch_from_single(texts, opts) do
      embeddings =
        Enum.map(texts, fn t ->
          {:ok, r} = embed(t, opts)
          r.embedding
        end)

      dims = Keyword.get(opts, :dimensions, 768)

      %{
        embeddings: embeddings,
        model: "test-model",
        provider: :test,
        usage: %{prompt_tokens: 0, total_tokens: 0},
        dimensions: dims
      }
    end
  end

  defmodule BlankModelEmbed do
    @behaviour Arbor.Contracts.API.Embedding

    @impl true
    def embed(_text, opts) do
      dims = Keyword.get(opts, :dimensions, 768)

      {:ok,
       %{
         embedding: Enum.map(1..dims, fn _ -> 0.0 end),
         model: "   ",
         provider: :test,
         usage: %{prompt_tokens: 0, total_tokens: 0},
         dimensions: dims
       }}
    end

    @impl true
    def embed_batch(_texts, _opts), do: {:error, :not_implemented}
  end

  defmodule FailEmbed do
    @behaviour Arbor.Contracts.API.Embedding

    @impl true
    def embed(_text, _opts), do: {:error, :provider_down}

    @impl true
    def embed_batch(_texts, _opts), do: {:error, :provider_down}
  end

  defmodule WrongDimsEmbed do
    @behaviour Arbor.Contracts.API.Embedding

    @impl true
    def embed(_text, _opts) do
      {:ok,
       %{
         embedding: [0.1, 0.2, 0.3],
         model: "tiny",
         provider: :test,
         usage: %{prompt_tokens: 0, total_tokens: 0},
         dimensions: 3
       }}
    end

    @impl true
    def embed_batch(_texts, _opts), do: {:error, :not_implemented}
  end

  defmodule FakePersistence do
    @table :skill_hybrid_fake_persistence

    def reset do
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
      :ets.new(@table, [:named_table, :public, :set])
      :ets.insert(@table, {:embed_calls, 0})
      :ets.insert(@table, {:hybrid_calls, 0})
      :ets.insert(@table, {:capability_calls, 0})
      :ets.insert(@table, {:capability, :postgres})
      :ok
    end

    def set_capability(cap), do: :ets.insert(@table, {:capability, cap})

    def embed_calls do
      case :ets.lookup(@table, :embed_calls) do
        [{:embed_calls, n}] -> n
        _ -> 0
      end
    end

    def hybrid_calls do
      case :ets.lookup(@table, :hybrid_calls) do
        [{:hybrid_calls, n}] -> n
        _ -> 0
      end
    end

    def capability_calls do
      case :ets.lookup(@table, :capability_calls) do
        [{:capability_calls, n}] -> n
        _ -> 0
      end
    end

    def last_hybrid_args do
      case :ets.lookup(@table, :last_hybrid) do
        [{:last_hybrid, args}] -> args
        _ -> nil
      end
    end

    def last_upsert do
      case :ets.lookup(@table, :last_upsert) do
        [{:last_upsert, attrs}] -> attrs
        _ -> nil
      end
    end

    def skill_search_capability do
      bump(:capability_calls)

      case :ets.lookup(@table, :capability) do
        [{:capability, cap}] -> cap
        _ -> :unavailable
      end
    end

    def hybrid_search_skills(query, embedding \\ nil, opts \\ []) do
      {:ok, %{results: results}} = hybrid_search_skills_with_meta(query, embedding, opts)
      results
    end

    def hybrid_search_skills_with_meta(query, query_embedding, opts) do
      bump(:hybrid_calls)
      :ets.insert(@table, {:last_hybrid, {query, query_embedding, opts}})

      results =
        case :ets.lookup(@table, :search_results) do
          [{:search_results, r}] -> r
          _ -> []
        end

      qe_stat = if is_list(query_embedding), do: :ok, else: :skipped_no_query_embedding
      mode = if is_list(query_embedding), do: :hybrid, else: :bm25_only

      {:ok,
       %{
         results: results,
         meta: %{
           mode: mode,
           backend: :postgres,
           capability: :postgres,
           query_embedding: qe_stat,
           bm25_arm: if(results == [], do: :empty, else: :executed),
           vector_arm:
             if(is_list(query_embedding),
               do: if(results == [], do: :empty, else: :executed),
               else: :skipped_no_query_embedding
             ),
           fusion: if(is_list(query_embedding), do: :rrf, else: :none),
           result_count: length(results),
           reason: if(results == [], do: :zero_results, else: nil)
         }
       }}
    end

    def upsert_skills(list) when is_list(list) do
      Enum.each(list, &upsert_skill/1)
      {:ok, length(list)}
    end

    def upsert_skill(attrs) when is_map(attrs) do
      :ets.insert(@table, {:last_upsert, attrs})
      name = attrs[:name] || attrs["name"]
      existing = get_skill_record(name) || %{}
      normalized = atomize_known(attrs)

      stored =
        existing
        |> Map.merge(normalized)
        |> then(fn m ->
          # Preserve embedding/space when omitted (outage semantics).
          m
          |> maybe_keep(existing, :embedding, normalized)
          |> maybe_keep(existing, :embedding_space, normalized)
        end)

      :ets.insert(@table, {{:skill, name}, stored})
      {:ok, stored}
    end

    def get_skill_record(name) do
      case :ets.lookup(@table, {:skill, name}) do
        [{{:skill, ^name}, rec}] -> rec
        _ -> nil
      end
    end

    def set_search_results(results), do: :ets.insert(@table, {:search_results, results})

    def note_embed do
      bump(:embed_calls)
    end

    defp bump(key) do
      n =
        case :ets.lookup(@table, key) do
          [{^key, v}] -> v
          _ -> 0
        end

      :ets.insert(@table, {key, n + 1})
    end

    defp maybe_keep(stored, existing, key, attrs) do
      if Map.has_key?(attrs, key) do
        stored
      else
        case Map.get(existing, key) do
          nil -> Map.delete(stored, key)
          val -> Map.put(stored, key, val)
        end
      end
    end

    @known_keys [
      :name,
      :description,
      :body,
      :tags,
      :category,
      :source,
      :path,
      :license,
      :compatibility,
      :allowed_tools,
      :content_hash,
      :taint,
      :provenance,
      :metadata,
      :embedding,
      :embedding_space
    ]

    defp atomize_known(attrs) do
      Map.new(@known_keys, fn key ->
        val = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
        {key, val}
      end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end
  end

  defmodule CountingEmbed do
    @behaviour Arbor.Contracts.API.Embedding

    @impl true
    def embed(text, opts) do
      FakePersistence.note_embed()
      SuccessEmbed.embed(text, opts)
    end

    @impl true
    def embed_batch(texts, opts), do: SuccessEmbed.embed_batch(texts, opts)
  end

  setup do
    stop_skill_library()
    if :ets.whereis(:arbor_skill_library) != :undefined, do: :ets.delete(:arbor_skill_library)

    FakePersistence.reset()

    original_embed = Application.get_env(:arbor_common, :skill_embedding_module, :not_set)
    original_persist = Application.get_env(:arbor_common, :skill_persistence_module, :not_set)

    Application.put_env(:arbor_common, :skill_embedding_module, SuccessEmbed)
    Application.put_env(:arbor_common, :skill_persistence_module, FakePersistence)

    on_exit(fn ->
      restore(:skill_embedding_module, original_embed)
      restore(:skill_persistence_module, original_persist)

      stop_skill_library()
      if :ets.whereis(:arbor_skill_library) != :undefined, do: :ets.delete(:arbor_skill_library)
    end)

    {:ok, _pid} = SkillLibrary.start_link(dirs: [])
    :ok
  end

  defp restore(key, :not_set), do: Application.delete_env(:arbor_common, key)
  defp restore(key, value), do: Application.put_env(:arbor_common, key, value)

  defp stop_skill_library do
    case Process.whereis(SkillLibrary) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid)
    end
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _} -> :ok
  end

  defp register_skill(name, desc \\ "A skill about alpha beta workflows") do
    {:ok, skill} =
      Skill.new(%{
        name: name,
        description: desc,
        body: "body for #{name}",
        tags: ["test"],
        category: "test"
      })

    assert :ok = SkillLibrary.register(skill)
    skill
  end

  describe "EmbeddingText" do
    test "builds canonical labeled text" do
      text =
        EmbeddingText.for_skill(%{
          name: "foo",
          description: "desc",
          category: "cat",
          tags: ["b", "a"],
          body: " hello "
        })

      assert text =~ "name: foo"
      assert text =~ "description: desc"
      assert text =~ "category: cat"
      assert text =~ "tags: a, b"
      assert text =~ "hello"
      refute text =~ "path:"
    end
  end

  describe "sync_to_store with embeddings" do
    test "writes embedding and embedding_space when service succeeds" do
      register_skill("sync-ok")
      assert {:ok, 1} = SkillLibrary.sync_to_store()

      upsert = FakePersistence.last_upsert()
      assert is_list(upsert.embedding)
      assert length(upsert.embedding) == 768
      assert upsert.embedding_space["provider"] == "test"
      assert upsert.embedding_space["model"] == "test-model"
      assert upsert.embedding_space["dimensions"] == 768
    end

    test "omits embedding and space keys on embed failure (preserves prior)" do
      skill = register_skill("sync-preserve")
      prior_vec = Enum.map(1..768, fn i -> i * 0.001 end)

      # Seed a prior vector directly so the failure path cannot skip re-embed
      # via content_hash short-circuit alone.
      assert {:ok, _} =
               FakePersistence.upsert_skill(%{
                 name: "sync-preserve",
                 description: skill.description,
                 body: skill.body,
                 content_hash: :crypto.hash(:sha256, skill.body) |> Base.encode16(case: :lower),
                 embedding: prior_vec,
                 embedding_space: %{
                   "provider" => "test",
                   "model" => "prior-model",
                   "dimensions" => 768
                 }
               })

      # Force re-embed attempt by changing body (new content_hash) while embed fails.
      {:ok, updated} =
        Skill.new(%{
          name: "sync-preserve",
          description: skill.description,
          body: skill.body <> " changed",
          tags: skill.tags,
          category: skill.category
        })

      assert :ok = SkillLibrary.register(updated)

      Application.put_env(:arbor_common, :skill_embedding_module, FailEmbed)
      assert {:ok, 1} = SkillLibrary.sync_to_store()
      second = FakePersistence.get_skill_record("sync-preserve")

      assert second.embedding == prior_vec
      assert second.embedding_space["model"] == "prior-model"
      refute Map.has_key?(FakePersistence.last_upsert(), :embedding)
      refute Map.has_key?(FakePersistence.last_upsert(), :embedding_space)
    end

    test "invalid dimensions do not persist vectors" do
      register_skill("sync-bad-dims")
      Application.put_env(:arbor_common, :skill_embedding_module, WrongDimsEmbed)
      assert {:ok, 1} = SkillLibrary.sync_to_store()
      upsert = FakePersistence.last_upsert()
      refute Map.has_key?(upsert, :embedding)
      refute Map.has_key?(upsert, :embedding_space)
    end
  end

  describe "hybrid_search_with_meta" do
    test "query embedding is passed when service succeeds" do
      register_skill("search-ok", "alpha beta lexical")

      FakePersistence.set_search_results([
        %{name: "search-ok", description: "alpha beta lexical"}
      ])

      assert {:ok, %{results: results, meta: meta}} =
               SkillLibrary.hybrid_search_with_meta("alpha beta", limit: 5)

      assert length(results) == 1
      {_q, embedding, opts} = FakePersistence.last_hybrid_args()
      assert is_list(embedding)
      assert length(embedding) == 768
      assert is_map(opts[:embedding_space])
      assert meta.mode == :hybrid
      assert meta.query_embedding == :ok
      assert meta.capability == :postgres
      assert SuccessEmbed.last_opts()[:dimensions] == 768
    end

    test "no-service yields BM25 path metadata and zero-result observability" do
      Application.put_env(:arbor_common, :skill_embedding_module, nil)
      FakePersistence.set_search_results([])

      assert {:ok, %{results: [], meta: meta}} =
               SkillLibrary.hybrid_search_with_meta("zzzz-no-match")

      assert meta.query_embedding == :no_service
      assert meta.mode == :bm25_only
      assert meta.reason == :zero_results
      assert meta.result_count == 0
      {_q, embedding, _opts} = FakePersistence.last_hybrid_args()
      assert is_nil(embedding)
    end

    test "blank model is rejected as invalid and does not pass a query vector" do
      Application.put_env(:arbor_common, :skill_embedding_module, BlankModelEmbed)
      FakePersistence.set_search_results([])

      assert {:ok, %{meta: meta}} = SkillLibrary.hybrid_search_with_meta("query")
      assert meta.query_embedding == :invalid
      {_q, embedding, _opts} = FakePersistence.last_hybrid_args()
      assert is_nil(embedding)
    end

    test "list APIs remain compatible" do
      FakePersistence.set_search_results([%{name: "listed", description: "x"}])
      assert is_list(SkillLibrary.search("anything"))
      assert is_list(SkillLibrary.hybrid_search("anything"))
    end

    test "search hybrid: false on postgres-capable backend uses forced-off metadata" do
      FakePersistence.set_capability(:postgres)
      register_skill("forced-ets-skill", "alpha forced keyword")
      Application.put_env(:arbor_common, :skill_embedding_module, CountingEmbed)

      assert {:ok, %{results: results, meta: meta}} =
               SkillLibrary.search_with_meta("alpha", hybrid: false)

      assert FakePersistence.embed_calls() == 0
      assert FakePersistence.hybrid_calls() == 0
      assert meta.mode == :ets_keyword
      assert meta.capability == :postgres
      assert meta.backend == :ets
      assert meta.reason == :hybrid_forced_off
      assert meta.bm25_arm == :skipped_forced_off
      assert meta.vector_arm == :skipped_forced_off
      assert meta.query_embedding == :not_attempted
      refute meta.bm25_arm == :skipped_not_postgres
      refute meta.vector_arm == :skipped_not_postgres
      assert Enum.any?(results, fn s -> Map.get(s, :name) == "forced-ets-skill" end)

      # List API also honors hybrid: false
      assert is_list(SkillLibrary.search("alpha", hybrid: false))
    end
  end

  describe "startup sync retry" do
    test "startup sync retries until capability becomes postgres" do
      # Stop the default setup library and reconfigure with short retry windows.
      stop_skill_library()

      if :ets.whereis(:arbor_skill_library) != :undefined do
        :ets.delete(:arbor_skill_library)
      end

      original_initial =
        Application.get_env(:arbor_common, :skill_sync_initial_delay_ms, :not_set)

      original_retry =
        Application.get_env(:arbor_common, :skill_sync_retry_delay_ms, :not_set)

      original_max =
        Application.get_env(:arbor_common, :skill_sync_max_attempts, :not_set)

      Application.put_env(:arbor_common, :skill_sync_initial_delay_ms, 20)
      Application.put_env(:arbor_common, :skill_sync_retry_delay_ms, 20)
      Application.put_env(:arbor_common, :skill_sync_max_attempts, 40)
      Application.put_env(:arbor_common, :skill_embedding_module, SuccessEmbed)
      Application.put_env(:arbor_common, :skill_persistence_module, FakePersistence)

      FakePersistence.reset()
      FakePersistence.set_capability(:unavailable)

      on_exit(fn ->
        restore(:skill_sync_initial_delay_ms, original_initial)
        restore(:skill_sync_retry_delay_ms, original_retry)
        restore(:skill_sync_max_attempts, original_max)
      end)

      assert {:ok, _pid} = SkillLibrary.start_link(dirs: [])
      # Skill registered while persistence is still unavailable; retries continue.
      register_skill("startup-retry-skill")
      assert is_nil(FakePersistence.get_skill_record("startup-retry-skill"))

      assert wait_until(fn -> FakePersistence.capability_calls() > 0 end, 1_000)
      assert is_nil(FakePersistence.get_skill_record("startup-retry-skill"))

      FakePersistence.set_capability(:postgres)

      # Wait for a successful startup sync attempt.
      assert wait_until(
               fn -> FakePersistence.get_skill_record("startup-retry-skill") != nil end,
               2_000
             )

      record = FakePersistence.get_skill_record("startup-retry-skill")
      assert record.name == "startup-retry-skill"
      assert is_list(record.embedding)
      assert is_map(record.embedding_space)
    end

    test "explicit sync_to_store remains immediate when capable" do
      register_skill("explicit-sync-skill")
      FakePersistence.set_capability(:postgres)
      assert {:ok, 1} = SkillLibrary.sync_to_store()
      assert FakePersistence.get_skill_record("explicit-sync-skill")
    end

    test "invalid skill_persistence_module config does not crash init or search" do
      stop_skill_library()
      if :ets.whereis(:arbor_skill_library) != :undefined, do: :ets.delete(:arbor_skill_library)

      Application.put_env(:arbor_common, :skill_persistence_module, "not-a-module")
      Application.put_env(:arbor_common, :skill_embedding_module, SuccessEmbed)

      assert {:ok, pid} = SkillLibrary.start_link(dirs: [])
      assert Process.alive?(pid)
      register_skill("bad-config-skill", "alpha bad config")

      assert {:ok, %{results: results, meta: meta}} =
               SkillLibrary.search_with_meta("alpha")

      assert meta.capability == :unavailable
      assert meta.mode == :ets_keyword
      assert Enum.any?(results, fn s -> Map.get(s, :name) == "bad-config-skill" end)

      # Restore valid fake for remaining tests / on_exit.
      Application.put_env(:arbor_common, :skill_persistence_module, FakePersistence)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  describe "capability before embed" do
    test "ets_only does not call embed or hybrid persistence search" do
      Application.put_env(:arbor_common, :skill_embedding_module, CountingEmbed)
      FakePersistence.set_capability(:ets_only)
      register_skill("ets-only-skill", "alpha keyword skill")

      assert {:ok, %{results: results, meta: meta}} =
               SkillLibrary.hybrid_search_with_meta("alpha")

      assert FakePersistence.embed_calls() == 0
      assert FakePersistence.hybrid_calls() == 0
      assert meta.mode == :ets_keyword
      assert meta.capability == :ets_only
      assert meta.query_embedding == :not_attempted
      assert meta.reason == :sqlite_or_non_postgres
      assert Enum.any?(results, fn s -> Map.get(s, :name) == "ets-only-skill" end)
    end

    test "unavailable seam uses ETS and skips embed" do
      Application.put_env(:arbor_common, :skill_persistence_module, nil)
      Application.put_env(:arbor_common, :skill_embedding_module, CountingEmbed)
      register_skill("local-only", "beta local skill")

      assert {:ok, %{results: results, meta: meta}} =
               SkillLibrary.search_with_meta("beta")

      assert FakePersistence.embed_calls() == 0
      assert meta.mode == :ets_keyword
      assert meta.capability == :unavailable
      assert meta.query_embedding == :not_attempted
      assert Enum.any?(results, fn s -> Map.get(s, :name) == "local-only" end)
    end

    test "ets_only sync does not embed" do
      Application.put_env(:arbor_common, :skill_embedding_module, CountingEmbed)
      FakePersistence.set_capability(:ets_only)
      register_skill("text-only-sync")

      assert {:ok, 1} = SkillLibrary.sync_to_store()
      assert FakePersistence.embed_calls() == 0
      upsert = FakePersistence.last_upsert()
      refute Map.has_key?(upsert, :embedding)
    end
  end
end
