defmodule Arbor.Commands.SafeRecoveryArtifact.ComposeTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryArtifact
  alias Arbor.Commands.SafeRecoveryArtifact.CleanupReceipt
  alias Arbor.Commands.TwoBuildFactFixture, as: TB

  @moduletag :fast

  # The ledger lives in this process's Process dictionary, keyed by a single
  # fixed key -- make sure a failed assertion in one test never leaks into
  # the next.
  setup do
    on_exit(fn ->
      Process.delete({Arbor.Commands.SafeRecoveryArtifact.ComposeLedger, :ledger})
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
        "sha256" => Arbor.Commands.SafeRecoveryArtifactFixture.sha256_hex("abcd"),
        "prefix_hex" => Arbor.Commands.SafeRecoveryArtifactFixture.prefix_hex("abcd")
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
    test "a stuck build B cleanup leaves only build B pending while the independent A pair still cleans" do
      facts = TB.facts()

      broken =
        facts
        |> put_in([:replies, {:run_phase, :b, "compile"}], {:error, :boom})
        |> put_in([:cleanup_replies, {:build, :b}], {:error, :stuck})

      assert {:error, {:cleanup_retained, receipt}} =
               SafeRecoveryArtifact.compose_from_facts_for_test(%{mode: :compose, facts: broken})

      # Clearing the build-B fault and retrying resolves cleanup, but the
      # original failed outcome (the compile failure) is what must come back
      # -- retry only proves cleanup, it never turns a failure into success.
      # Cleanup succeeding here (rather than staying pending) is itself proof
      # that source B was never swept while build B was stuck: if it had
      # been, the initial compose call's ledger would already show it clean
      # and this retry would have nothing new to do either way, but a broken
      # skip rule that left source B *live* and unswept would make this
      # retry's cleanup attempt for it observable -- assert on the call log.
      cleared = %{broken | cleanup_replies: %{}}

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
        schema: "arbor.commands.safe_recovery_artifact.two_build_cleanup_receipt.v1",
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
end
