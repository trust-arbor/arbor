defmodule Arbor.Commands.SafeRecoveryArtifact.ComposeTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryArtifact

  alias Arbor.Commands.SafeRecoveryArtifact.{
    CleanupReceipt,
    ComposeFactInterpreter,
    ComposeLedger,
    ComposeShell
  }

  alias Arbor.Commands.SafeRecoveryArtifactFixture, as: Fixture
  alias Arbor.Commands.TwoBuildFactFixture, as: TB

  @moduletag :fast

  # The ledger lives in this process's Process dictionary under
  # domain-scoped keys (:production, :fact) -- each ExUnit test is its own
  # process so these die with the process regardless, but clear both
  # explicitly for defensive hygiene.
  setup do
    on_exit(fn ->
      ComposeLedger.delete(:production)
      ComposeLedger.delete(:fact)
    end)

    :ok
  end

  describe "closed opts" do
    test "compose/1 rejects a non-keyword argument" do
      assert {:error, :invalid_opts} = SafeRecoveryArtifact.compose(%{root: "/tmp"})
    end
  end

  describe "compose_from_facts_for_test/1 happy path" do
    test "projects a manifest with identical reproducibility" do
      assert {:ok, manifest} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :compose,
                 facts: TB.facts()
               })

      assert manifest["reproducibility"]["status"] == "identical"
      assert manifest["reproducibility"]["differing_paths"] == []
      assert is_list(manifest["findings"])
    end

    test "rejects unknown mode/facts shapes" do
      assert {:error, :invalid_opts} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :bogus})

      assert {:error, :invalid_opts} =
               SafeRecoveryArtifact.compose_from_facts_for_test("not a map")
    end
  end

  describe "exact operation trace" do
    test "the fixed step order is observed exactly: slot A's full precompile before slot B's, both before compile" do
      facts = Map.put(TB.facts(), :trace_pid, self())

      assert {:ok, _manifest} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: facts})

      assert drain(:composer_step) == [
               {:stage_source, :a},
               {:stage_source, :b},
               {:acquire_build, :a},
               {:acquire_build, :b},
               {:run_phase, :a, "deps_get"},
               {:stage_native, :a},
               {:inventory_deps, :a},
               {:run_phase, :b, "deps_get"},
               {:stage_native, :b},
               {:inventory_deps, :b},
               {:run_phase, :a, "compile"},
               {:run_phase, :b, "compile"},
               {:run_phase, :a, "release"},
               {:run_phase, :b, "release"},
               {:remove_cookie, :a},
               {:remove_cookie, :b},
               {:inventory_release, :a},
               {:inventory_release, :b},
               {:read_descriptors, :a},
               {:read_descriptors, :b}
             ]
    end
  end

  describe "source and dependency disagreement" do
    test "disagreeing commit fails closed with :source_fact_disagreement" do
      facts = TB.facts()

      mismatched =
        put_in(
          facts.replies[{:stage_source, :b}],
          {:ok, %{TB.source_lease() | "commit" => String.duplicate("f", 40)}}
        )

      assert {:error, :source_fact_disagreement} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :compose,
                 facts: mismatched
               })
    end

    test "disagreeing dependency inventories fail closed before either compile is even offered a reply" do
      facts = TB.facts()
      {other_deps, _} = TB.release_inventory()

      mismatched =
        facts
        |> put_in([:replies, {:inventory_deps, :b}], {:ok, %{other_deps | "kind" => "deps"}})
        # Remove the compile replies entirely -- if the gate is broken and
        # compile is attempted anyway, the fixture interpreter has nothing to
        # answer with and the test fails loudly instead of silently passing.
        |> update_in(
          [:replies],
          &Map.drop(&1, [{:run_phase, :a, "compile"}, {:run_phase, :b, "compile"}])
        )

      assert {:error, :dependency_inventory_disagreement} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :compose,
                 facts: mismatched
               })
    end
  end

  describe "phase admission" do
    test "a non-zero exit code fails closed" do
      facts = TB.facts()

      bad =
        put_in(
          facts.replies[{:run_phase, :a, "deps_get"}],
          {:ok, %{exit_code: 1, timed_out: false, killed: false}}
        )

      assert {:error, {:trusted_build_phase_failed, :a, "deps_get", _result}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: bad})
    end

    test "a timed-out phase fails closed" do
      facts = TB.facts()

      bad =
        put_in(
          facts.replies[{:run_phase, :b, "compile"}],
          {:ok, %{exit_code: 0, timed_out: true, killed: false}}
        )

      assert {:error, {:trusted_build_phase_failed, :b, "compile", _result}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: bad})
    end

    test "a killed phase fails closed" do
      facts = TB.facts()

      bad =
        put_in(
          facts.replies[{:run_phase, :a, "release"}],
          {:ok, %{exit_code: 0, timed_out: false, killed: true}}
        )

      assert {:error, {:trusted_build_phase_failed, :a, "release", _result}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: bad})
    end

    test "a phase result missing required fields fails closed rather than being treated as success" do
      facts = TB.facts()
      bad = put_in(facts.replies[{:run_phase, :a, "deps_get"}], {:ok, %{exit_code: 0}})

      assert {:error, {:trusted_build_phase_failed, :a, "deps_get", %{exit_code: 0}}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: bad})
    end

    test "a string exit_code fails closed rather than being coerced" do
      facts = TB.facts()

      bad =
        put_in(
          facts.replies[{:run_phase, :b, "deps_get"}],
          {:ok, %{exit_code: "0", timed_out: false, killed: false}}
        )

      assert {:error, {:trusted_build_phase_failed, :b, "deps_get", _result}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: bad})
    end
  end

  describe "release-root rebasing" do
    test "a sibling segment is rejected" do
      facts = TB.facts()
      {release, bytes} = TB.release_inventory()

      sibling =
        update_in(release["directories"], fn dirs ->
          dirs
          |> Enum.map(fn
            %{"path" => "arbor_trust"} = row -> %{row | "path" => "arbor_trust_extra"}
            row -> row
          end)
          |> Enum.sort_by(& &1["path"])
        end)

      broken =
        facts
        |> put_in([:replies, {:inventory_release, :a}], {:ok, sibling})
        |> put_in(
          [:replies, {:read_descriptors, :a}],
          {:ok, TB.descriptor_replies(release, bytes)}
        )

      assert {:error, :release_root_segment_mismatch} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})
    end

    test "a surviving releases/COOKIE row is rejected" do
      facts = TB.facts()
      {release, bytes} = TB.release_inventory()

      cookie_row = %{
        "path" => "arbor_trust/releases/COOKIE",
        "mode" => 0o644,
        "executable" => false,
        "size" => 4,
        "sha256" => Fixture.sha256_hex("abcd"),
        "prefix_hex" => Fixture.prefix_hex("abcd")
      }

      with_cookie =
        release
        |> update_in(["regular_files"], &Enum.sort_by([cookie_row | &1], fn f -> f["path"] end))
        |> update_in(["counts", "regular_files"], &(&1 + 1))
        |> update_in(["counts", "entries"], &(&1 + 1))
        |> update_in(["counts", "total_regular_bytes"], &(&1 + 4))

      broken = put_in(facts.replies[{:inventory_release, :a}], {:ok, with_cookie})
      _ = bytes

      assert {:error, :cookie_present} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})
    end

    test "a regular file at the exact root path is rejected, never silently dropped as if it were the root directory" do
      facts = TB.facts()
      {release, bytes} = TB.release_inventory()

      root_file = %{
        "path" => "arbor_trust",
        "mode" => 0o644,
        "executable" => false,
        "size" => 4,
        "sha256" => Fixture.sha256_hex("evil"),
        "prefix_hex" => Fixture.prefix_hex("evil")
      }

      # No legitimate "arbor_trust" directory row remains -- this is the
      # scenario that previously let a malicious file silently masquerade as
      # (and be dropped in place of) the root directory row.
      poisoned =
        release
        |> update_in(
          ["directories"],
          &Enum.reject(&1, fn row -> row["path"] == "arbor_trust" end)
        )
        |> update_in(["counts", "directories"], &(&1 - 1))
        |> update_in(["regular_files"], &Enum.sort_by([root_file | &1], fn f -> f["path"] end))
        |> update_in(["counts", "regular_files"], &(&1 + 1))
        |> update_in(["counts", "total_regular_bytes"], &(&1 + 4))

      broken = put_in(facts.replies[{:inventory_release, :a}], {:ok, poisoned})
      _ = bytes

      assert {:error, :release_root_not_a_directory} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})
    end
  end

  describe "descriptor exactness" do
    test "a missing attested descriptor is rejected" do
      facts = TB.facts()
      {release, bytes} = TB.release_inventory()
      [_drop | rest] = TB.descriptor_replies(release, bytes)

      broken = put_in(facts.replies[{:read_descriptors, :a}], {:ok, rest})

      assert {:error, :missing_descriptor} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})
    end

    test "an extra descriptor outside the inventory is rejected" do
      facts = TB.facts()
      {release, bytes} = TB.release_inventory()
      extra = %{"path" => "arbor_trust/lib/unexpected-0.1.0/ebin/unexpected.app", "bytes" => "{}"}

      broken =
        put_in(
          facts.replies[{:read_descriptors, :a}],
          {:ok, [extra | TB.descriptor_replies(release, bytes)]}
        )

      assert {:error, :extra_descriptor} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})
    end
  end

  describe "receipt opacity and busy ledger" do
    test "a retained-cleanup receipt exposes only schema/owner/token" do
      facts = TB.facts()

      broken =
        facts
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      assert %CleanupReceipt{} = receipt
      assert Map.from_struct(receipt) |> Map.keys() |> Enum.sort() == [:owner, :schema, :token]
      assert receipt.owner == self()
      assert is_binary(receipt.token)
    end

    test "a second compose while a receipt is outstanding is rejected as busy" do
      facts = TB.facts()

      broken =
        facts
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, _receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      assert {:error, :cleanup_ledger_busy} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :compose,
                 facts: TB.facts()
               })
    end
  end

  describe "skip-source-on-build-cleanup-failure" do
    test "a stuck build B cleanup leaves only build B pending; source B is never attempted while pair A cleans in full" do
      facts =
        TB.facts()
        |> Map.put(:trace_pid, self())
        |> put_in([:replies, {:run_phase, :b, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :b}], {:error, :stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: facts})

      attempts = drain(:cleanup_attempt)

      assert {:build, :b} in attempts
      refute {:source, :b} in attempts
      assert {:build, :a} in attempts
      assert {:source, :a} in attempts

      cleared = %{facts | cleanup_replies: %{}}

      assert {:error, {:trusted_build_phase_failed, :b, "compile", :boom}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: receipt,
                 facts: cleared
               })
    end
  end

  describe "malformed C1 identity retention" do
    test "a malformed identity from a C1 cleanup_retained result stays pending and is never dropped" do
      facts = TB.facts()
      malformed_identity = %{"not" => "a well-formed identity"}

      broken =
        facts
        |> put_in(
          [:replies, {:stage_source, :b}],
          {:error, {:cleanup_retained, :forced, malformed_identity}}
        )
        |> put_in([:cleanup_replies, {:source, :b}], {:error, :rejected_malformed})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      # Retrying with the fixture still rejecting the malformed identity
      # keeps it pending rather than silently dropping it.
      still_broken = put_in(broken.cleanup_replies[{:source, :b}], {:error, :still_malformed})

      assert {:error, {:cleanup_retained, ^receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: receipt,
                 facts: still_broken
               })
    end
  end

  describe "C1 identity/3-tuple never escapes into the outcome" do
    test "immediate resolution never returns the raw {:cleanup_retained, reason, identity} tuple or the identity" do
      malformed_identity = %{"path" => "/private/should/never/be/returned", "inode" => 1}

      facts =
        put_in(
          TB.facts().replies[{:stage_source, :b}],
          {:error, {:cleanup_retained, :forced, malformed_identity}}
        )

      # Cleanup resolves immediately (default fixture reply is :ok), so the
      # sanitized outcome is what settle/1 returns directly.
      assert {:error, reason} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: facts})

      assert reason == {:source_staging_failed, :b, :forced}
      refute match?({:cleanup_retained, _, _}, reason)
      refute inspect(reason) =~ "should never be returned"
    end

    test "retried resolution also never returns the raw tuple or the identity" do
      malformed_identity = %{"path" => "/private/should/never/be/returned", "inode" => 1}

      facts =
        TB.facts()
        |> put_in(
          [:replies, {:stage_source, :b}],
          {:error, {:cleanup_retained, :forced, malformed_identity}}
        )
        |> put_in([:cleanup_replies, {:source, :b}], {:error, :still_stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: facts})

      cleared = %{facts | cleanup_replies: %{}}

      assert {:error, reason} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: receipt,
                 facts: cleared
               })

      assert reason == {:source_staging_failed, :b, :forced}
      refute match?({:cleanup_retained, _, _}, reason)
      refute inspect(reason) =~ "should never be returned"
    end
  end

  describe "retry semantics" do
    test "retry resolves to the preserved outcome once the fault is cleared" do
      facts = TB.facts()

      broken =
        facts
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      cleared = %{broken | cleanup_replies: %{}}

      assert {:error, {:trusted_build_phase_failed, :a, "compile", :boom}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: receipt,
                 facts: cleared
               })
    end

    test "a wrong token against an active ledger is rejected, and the real episode remains resolvable" do
      facts =
        TB.facts()
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, real_receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: facts})

      wrong_token = %{real_receipt | token: :crypto.strong_rand_bytes(32)}

      assert {:error, :invalid_cleanup_receipt} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: wrong_token,
                 facts: facts
               })

      cleared = %{facts | cleanup_replies: %{}}

      assert {:error, {:trusted_build_phase_failed, :a, "compile", :boom}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: real_receipt,
                 facts: cleared
               })
    end

    test "replaying an already-fully-resolved receipt is rejected, not idempotent" do
      facts = TB.facts()

      broken =
        facts
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      cleared = %{broken | cleanup_replies: %{}}

      assert {:error, _reason} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: receipt,
                 facts: cleared
               })

      assert {:error, :invalid_cleanup_receipt} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: receipt,
                 facts: cleared
               })
    end

    test "retry from a different process is rejected as foreign" do
      facts = TB.facts()

      broken =
        facts
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      task =
        Task.async(fn ->
          SafeRecoveryArtifact.compose_from_facts_for_test(%{
            mode: :retry,
            receipt: receipt,
            facts: broken
          })
        end)

      assert {:error, :foreign_receipt} = Task.await(task)
    end

    test "a guessed-token, wrong-schema, or plain-map receipt is rejected without touching the ledger" do
      forged = %CleanupReceipt{
        schema: "wrong.schema",
        owner: self(),
        token: :crypto.strong_rand_bytes(32)
      }

      assert {:error, :invalid_cleanup_receipt} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: forged,
                 facts: TB.facts()
               })

      plain_map = %{
        schema: ComposeFactInterpreter.receipt_schema(),
        owner: self(),
        token: :crypto.strong_rand_bytes(32)
      }

      assert {:error, :invalid_cleanup_receipt} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: plain_map,
                 facts: TB.facts()
               })
    end
  end

  describe "SECURITY REGRESSION: fact and production episodes are fully isolated" do
    test "a fact-mode receipt is rejected by production retry_cleanup/1, and the fact episode remains untouched" do
      facts =
        TB.facts()
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, fact_receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: facts})

      # This is the reported vulnerability: before ledger-domain/receipt-
      # schema isolation, this call would match production's struct pattern
      # (identical shared schema), find the identical shared ledger, and
      # proceed into REAL Arbor.Shell/SourceStaging dispatch against fixture
      # placeholders -- never a clean rejection.
      assert {:error, :invalid_cleanup_receipt} = SafeRecoveryArtifact.retry_cleanup(fact_receipt)

      # The fact-mode episode itself is untouched by the rejected cross-mode
      # attempt -- it still resolves normally through its own retry.
      cleared = %{facts | cleanup_replies: %{}}

      assert {:error, {:trusted_build_phase_failed, :a, "compile", :boom}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: fact_receipt,
                 facts: cleared
               })
    end

    test "a production-schema receipt cannot resolve a live :fact-domain episode via retry_cleanup/1" do
      token = :crypto.strong_rand_bytes(32)
      :ok = ComposeLedger.try_acquire(:fact, token)
      :ok = ComposeLedger.record_build(:fact, :a, {:live, :fixture_handle_should_not_be_touched})

      forged = %CleanupReceipt{schema: ComposeShell.receipt_schema(), owner: self(), token: token}

      assert {:error, :invalid_cleanup_receipt} = SafeRecoveryArtifact.retry_cleanup(forged)

      # Untouched: still exactly the fixture placeholder planted above, under
      # the :fact domain only -- production's retry never reached it.
      assert {:ok, %{build: %{a: {:live, :fixture_handle_should_not_be_touched}}}} =
               ComposeLedger.fetch(:fact)

      ComposeLedger.delete(:fact)
    end

    test "a fact-schema receipt cannot resolve a live :production-domain episode via the fact retry mode" do
      token = :crypto.strong_rand_bytes(32)
      :ok = ComposeLedger.try_acquire(:production, token)

      :ok =
        ComposeLedger.record_build(:production, :a, {:live, :real_handle_should_not_be_touched})

      forged = %CleanupReceipt{
        schema: ComposeFactInterpreter.receipt_schema(),
        owner: self(),
        token: token
      }

      assert {:error, :invalid_cleanup_receipt} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{
                 mode: :retry,
                 receipt: forged,
                 facts: %{cleanup_replies: %{}}
               })

      assert {:ok, %{build: %{a: {:live, :real_handle_should_not_be_touched}}}} =
               ComposeLedger.fetch(:production)

      ComposeLedger.delete(:production)
    end
  end

  describe "exact terminal tag" do
    test "the retained-cleanup error is a literal 2-tuple {:cleanup_retained, receipt}" do
      facts = TB.facts()

      broken =
        facts
        |> put_in([:replies, {:run_phase, :a, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :a}], {:error, :stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      assert %CleanupReceipt{} = receipt
    end
  end

  describe "facade regression" do
    test "ComposeFactInterpreter never references Arbor.Shell or SourceStaging" do
      source =
        __ENV__.file
        |> Path.dirname()
        |> Path.join(
          "../../../../lib/arbor/commands/safe_recovery_artifact/compose_fact_interpreter.ex"
        )
        |> Path.expand()
        |> File.read!()

      refute source =~ "Arbor.Shell."
      refute source =~ "SourceStaging."
    end

    test "the cleanup dispatch path in ComposeShell and ComposeFactInterpreter takes no fun/MFA parameter" do
      for file <- ["compose_shell.ex", "compose_fact_interpreter.ex"] do
        source =
          __ENV__.file
          |> Path.dirname()
          |> Path.join("../../../../lib/arbor/commands/safe_recovery_artifact/#{file}")
          |> Path.expand()
          |> File.read!()

        refute source =~ "guarded(",
               "#{file} must not reintroduce a fun-parameter cleanup wrapper"
      end

      plan_source =
        __ENV__.file
        |> Path.dirname()
        |> Path.join("../../../../lib/arbor/commands/safe_recovery_artifact/cleanup_plan.ex")
        |> Path.expand()
        |> File.read!()

      refute plan_source =~ "fun.()"
      refute plan_source =~ ~r/def (next|record)\([^)]*fun/
    end

    test "the facade exports exactly the production compose surfaces plus the one inert fact boundary" do
      exports =
        SafeRecoveryArtifact.__info__(:functions)
        |> Enum.reject(fn {name, _arity} -> name == :module_info end)
        |> Enum.sort()

      assert exports == [
               {:compose, 0},
               {:compose, 1},
               {:compose_from_facts_for_test, 1},
               {:release_source, 1},
               {:release_source_for_test, 1},
               {:release_source_for_test, 2},
               {:retry_cleanup, 1},
               {:stage_source, 0},
               {:stage_source, 1},
               {:stage_source_for_test, 0},
               {:stage_source_for_test, 1}
             ]
    end
  end

  defp drain(tag, acc \\ []) do
    receive do
      {^tag, payload} -> drain(tag, [payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
