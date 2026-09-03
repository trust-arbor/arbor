defmodule Arbor.Commands.CodingGrantTrustCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingGrantTrustCore, as: Core

  @moduletag :fast

  @principal "agent_coordinator_grant"
  @recorded_uri "arbor://action/coding/design_council_review"
  @sibling_auto %{
    "arbor://action/coding/reviewed_commit" => :auto,
    "arbor://action/coding/workspace" => :auto
  }

  test "functional cores contain no impurity" do
    src = core_source()

    forbidden = [
      ~r/DateTime\.utc_now/,
      ~r/System\.(monotonic|os|system)_time/,
      ~r/:rand\./,
      ~r/:erlang\.unique_integer/,
      ~r/\bmake_ref\s*\(/,
      ~r/Application\.get_env/,
      ~r/GenServer\./,
      ~r/\bRepo\./,
      ~r/:ets\./,
      ~r/\bLogger\./
    ]

    Enum.each(forbidden, fn re ->
      refute Regex.match?(re, src), "impure pattern #{inspect(re.source)} in CodingGrantTrustCore"
    end)
  end

  test "module source never reaches Trust Store or Authority" do
    src = core_source()
    refute src =~ "Arbor.Trust.Store"
    refute src =~ "Arbor.Trust.Authority"
  end

  describe "decide/1 table" do
    test "no-rule installs the mirrored same-parent sibling mode" do
      assert {:ok, result} =
               decide([@recorded_uri], %{@recorded_uri => unmatched(:block)}, @sibling_auto)

      assert hd(result.decisions) == %{
               action: :install,
               uri: @recorded_uri,
               mode: :auto,
               reason: :mirrored_sibling
             }
    end

    test "existing rule is skipped" do
      assert {:ok, result} =
               decide(
                 [@recorded_uri],
                 %{@recorded_uri => %{effective_mode: :auto, user_match: {@recorded_uri, :auto}}},
                 @sibling_auto
               )

      assert hd(result.decisions) == %{
               action: :skip,
               uri: @recorded_uri,
               mode: :auto,
               reason: :existing_rule
             }
    end

    test "non-coding namespace is refused" do
      uri = "arbor://fs/read/tmp"

      assert {:ok, result} = decide([uri], %{uri => unmatched(:block)}, @sibling_auto)

      assert hd(result.decisions) == %{
               action: :refuse,
               uri: uri,
               mode: nil,
               reason: :non_coding_namespace
             }
    end

    test "conflicting same-parent siblings are refused" do
      siblings = %{
        "arbor://action/coding/reviewed_commit" => :auto,
        "arbor://action/coding/workspace" => :ask
      }

      assert {:ok, result} =
               decide([@recorded_uri], %{@recorded_uri => unmatched(:block)}, siblings)

      assert hd(result.decisions) == %{
               action: :refuse,
               uri: @recorded_uri,
               mode: nil,
               reason: :conflicting_siblings
             }
    end

    test "no siblings is refused" do
      assert {:ok, result} = decide([@recorded_uri], %{@recorded_uri => unmatched(:block)}, %{})

      assert hd(result.decisions) == %{
               action: :refuse,
               uri: @recorded_uri,
               mode: nil,
               reason: :no_siblings
             }
    end

    test "wildcard and root coding URIs are refused" do
      Enum.each(
        ["arbor://action/coding/**", "arbor://action/coding/*", "arbor://action/coding"],
        fn uri ->
          assert {:ok, result} = decide([uri], %{uri => unmatched(:block)}, @sibling_auto)

          assert hd(result.decisions) == %{
                   action: :refuse,
                   uri: uri,
                   mode: nil,
                   reason: :wildcard_or_root
                 }
        end
      )
    end

    test "unmatched already-permitted mode is skipped" do
      assert {:ok, result} =
               decide([@recorded_uri], %{@recorded_uri => unmatched(:auto)}, @sibling_auto)

      assert hd(result.decisions) == %{
               action: :skip,
               uri: @recorded_uri,
               mode: :auto,
               reason: :already_permitted
             }
    end

    test "missing explanation is refused" do
      assert {:ok, result} = decide([@recorded_uri], %{}, @sibling_auto)

      assert hd(result.decisions) == %{
               action: :refuse,
               uri: @recorded_uri,
               mode: nil,
               reason: :explain_failed
             }
    end

    test "errored explanation is refused" do
      assert {:ok, result} =
               decide([@recorded_uri], %{@recorded_uri => %{error: :rpc}}, @sibling_auto)

      assert hd(result.decisions).reason == :explain_failed
    end

    test "accepts required_resources as a resource_uris map" do
      assert {:ok, result} =
               decide(
                 %{"resource_uris" => [@recorded_uri]},
                 %{@recorded_uri => unmatched(:ask)},
                 @sibling_auto
               )

      assert hd(result.decisions).action == :install
      assert hd(result.decisions).mode == :auto
    end

    test "deeper ask validate rules are not siblings of a three-segment coding leaf" do
      siblings = %{
        "arbor://action/coding/reviewed_commit" => :auto,
        "arbor://action/coding/security_regression/validate" => :ask,
        "arbor://action/coding/cross_app/validate" => :ask
      }

      assert {:ok, result} =
               decide([@recorded_uri], %{@recorded_uri => unmatched(:block)}, siblings)

      assert hd(result.decisions) == %{
               action: :install,
               uri: @recorded_uri,
               mode: :auto,
               reason: :mirrored_sibling
             }
    end

    test "deduplicates required URIs in first-seen order" do
      assert {:ok, result} =
               decide(
                 [@recorded_uri, @recorded_uri],
                 %{@recorded_uri => unmatched(:block)},
                 @sibling_auto
               )

      assert length(result.decisions) == 1
    end

    test "rejects unknown input shapes" do
      assert {:error, :invalid_input} = Core.decide(%{})
      assert {:error, :invalid_input} = Core.decide(:nope)
    end
  end

  test "show/1 lists installed and refused without skip lines" do
    {:ok, result} =
      decide(
        [@recorded_uri, "arbor://fs/read/tmp"],
        %{
          @recorded_uri => unmatched(:block),
          "arbor://fs/read/tmp" => unmatched(:block)
        },
        @sibling_auto
      )

    shown = Core.show(result)
    assert shown =~ "trust rules:"
    assert shown =~ "execution_principal (#{@principal}):"
    assert shown =~ "installed:"
    assert shown =~ "#{@recorded_uri} => auto"
    assert shown =~ "refused:"
    assert shown =~ "arbor://fs/read/tmp (non_coding_namespace)"
    refute shown =~ "skipped"
  end

  test "show/1 uses dry-run would-install wording" do
    {:ok, result} = decide([@recorded_uri], %{@recorded_uri => unmatched(:block)}, @sibling_auto)
    shown = Core.show(Map.put(result, :dry_run, true))
    assert shown =~ "trust rules (dry-run):"
    assert shown =~ "would install:"
    assert shown =~ "#{@recorded_uri} => auto"
  end

  defp decide(required, explanations, sibling_rules) do
    Core.decide(%{
      principal_id: @principal,
      required_resources: required,
      explanations: explanations,
      sibling_rules: sibling_rules
    })
  end

  defp unmatched(mode), do: %{effective_mode: mode, user_match: nil}

  defp core_source do
    Path.expand("../../../lib/arbor/commands/coding_grant_trust_core.ex", __DIR__)
    |> File.read!()
  end
end
