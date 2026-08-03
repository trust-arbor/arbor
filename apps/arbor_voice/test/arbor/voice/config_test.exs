defmodule Arbor.Voice.ConfigTest do
  @moduledoc """
  Pure validation and literal-default tests for `Arbor.Voice.Config`'s
  `budget_*` accessors (VP-04B). No `Application.put_env`/`on_exit` anywhere
  in this file — the `validate_*/1,2` functions are tested directly with
  literal terms, and the thin wrapper tests read only whatever this app's
  checked-in `config/test.exs` already sets at compile time.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.Config

  describe "daily budget" do
    test "the literal default is 60 minutes" do
      assert Config.default_daily_budget_ms() == 3_600_000
    end

    test "validate_daily_budget_ms/1 accepts the default" do
      assert {:ok, 3_600_000} = Config.validate_daily_budget_ms(Config.default_daily_budget_ms())
    end

    test "validate_daily_budget_ms/1 fails closed on non-positive, non-integer, or above-ceiling values" do
      for bad <- [0, -1, 1.5, "60", nil, 86_400_001] do
        assert {:error, :invalid_config} = Config.validate_daily_budget_ms(bad)
      end
    end

    test "daily_budget_ms/0 resolves to the validated literal default under this app's checked-in config" do
      assert Config.daily_budget_ms() ==
               Config.validate_daily_budget_ms(Config.default_daily_budget_ms())
    end
  end

  describe "session budget" do
    test "validate_session_budget_ms/2 accepts a value no larger than the daily budget and ceiling" do
      assert {:ok, 1_800_000} = Config.validate_session_budget_ms(1_800_000, 3_600_000)
      assert {:ok, 3_600_000} = Config.validate_session_budget_ms(3_600_000, 3_600_000)
    end

    test "validate_session_budget_ms/2 fails closed when larger than the daily budget, ceiling, or malformed" do
      assert {:error, :invalid_config} = Config.validate_session_budget_ms(3_600_001, 3_600_000)
      assert {:error, :invalid_config} = Config.validate_session_budget_ms(86_400_001, 86_400_000)
      assert {:error, :invalid_config} = Config.validate_session_budget_ms(0, 3_600_000)
      assert {:error, :invalid_config} = Config.validate_session_budget_ms(-1, 3_600_000)
      assert {:error, :invalid_config} = Config.validate_session_budget_ms(1.0, 3_600_000)
    end

    test "session_budget_ms/0 defaults to the daily budget under this app's checked-in config" do
      assert Config.session_budget_ms() == Config.daily_budget_ms()
    end
  end

  describe "backend" do
    test "validate_budget_backend/1 accepts a module atom" do
      assert {:ok, Arbor.Persistence.QueryableStore.Postgres} =
               Config.validate_budget_backend(Arbor.Persistence.QueryableStore.Postgres)
    end

    test "validate_budget_backend/1 reports :disabled for nil" do
      assert {:error, :disabled} = Config.validate_budget_backend(nil)
    end

    test "validate_budget_backend/1 fails closed on a non-atom" do
      assert {:error, :invalid_config} = Config.validate_budget_backend("not-a-module")
    end

    test "budget_backend/0 fails closed under this app's checked-in test config (no backend configured)" do
      assert Config.budget_backend() == {:error, :disabled}
    end
  end

  describe "namespace" do
    test "the fixed namespace is :voice_daily_budgets" do
      assert Config.fixed_budget_namespace() == :voice_daily_budgets
    end

    test "validate_budget_namespace/1 accepts only the fixed value" do
      assert {:ok, :voice_daily_budgets} = Config.validate_budget_namespace(:voice_daily_budgets)
    end

    test "validate_budget_namespace/1 rejects any other value" do
      for bad <- [:other_namespace, "voice_daily_budgets", nil, :durable_interactions] do
        assert {:error, :invalid_config} = Config.validate_budget_namespace(bad)
      end
    end

    test "budget_namespace/0 resolves to the fixed value under this app's checked-in config" do
      assert Config.budget_namespace() == {:ok, :voice_daily_budgets}
    end
  end

  describe "backend opts" do
    test "validate_budget_backend_opts/1 accepts a keyword list without :name" do
      assert {:ok, [repo: Arbor.Persistence.Repo]} =
               Config.validate_budget_backend_opts(repo: Arbor.Persistence.Repo)

      assert {:ok, []} = Config.validate_budget_backend_opts([])
    end

    test "validate_budget_backend_opts/1 accepts nil values as JSON-clean" do
      assert {:ok, [pool: nil]} = Config.validate_budget_backend_opts(pool: nil)
    end

    test "validate_budget_backend_opts/1 fails closed on a :name key, duplicate keys, non-keyword-list, non-atom keys, oversized or disallowed values" do
      assert {:error, :invalid_config} = Config.validate_budget_backend_opts(name: :whatever)
      assert {:error, :invalid_config} = Config.validate_budget_backend_opts(repo: 1, repo: 2)
      assert {:error, :invalid_config} = Config.validate_budget_backend_opts(%{})
      assert {:error, :invalid_config} = Config.validate_budget_backend_opts("nope")
      assert {:error, :invalid_config} = Config.validate_budget_backend_opts([{"repo", nil}])

      assert {:error, :invalid_config} =
               Config.validate_budget_backend_opts(repo: %{nested: true})
    end

    test "validate_budget_backend_opts/1 fails closed when encoded size exceeds the cap" do
      opts =
        for i <- 1..32,
            do: {String.to_atom("k#{i}"), String.duplicate("x", 200)}

      assert {:error, :invalid_config} = Config.validate_budget_backend_opts(opts)
    end

    test "validate_budget_backend_opts/1 fails closed when count exceeds the cap" do
      opts = for i <- 1..33, do: {String.to_atom("k#{i}"), "v"}
      assert {:error, :invalid_config} = Config.validate_budget_backend_opts(opts)
    end
  end

  describe "reservation grace" do
    test "validate_budget_reservation_grace_ms/1 accepts the literal default" do
      assert {:ok, 60_000} = Config.validate_budget_reservation_grace_ms(60_000)
    end

    test "validate_budget_reservation_grace_ms/1 accepts zero" do
      assert {:ok, 0} = Config.validate_budget_reservation_grace_ms(0)
    end

    test "validate_budget_reservation_grace_ms/1 fails closed on a negative, non-integer, or above-ceiling value" do
      assert {:error, :invalid_config} = Config.validate_budget_reservation_grace_ms(-1)
      assert {:error, :invalid_config} = Config.validate_budget_reservation_grace_ms(1.0)
      assert {:error, :invalid_config} = Config.validate_budget_reservation_grace_ms(nil)
      assert {:error, :invalid_config} = Config.validate_budget_reservation_grace_ms(3_600_001)
    end
  end

  describe "CAS retry count" do
    test "validate_budget_cas_max_retries/1 accepts the bounded range" do
      assert {:ok, 0} = Config.validate_budget_cas_max_retries(0)
      assert {:ok, 5} = Config.validate_budget_cas_max_retries(5)
      assert {:ok, 20} = Config.validate_budget_cas_max_retries(20)
    end

    test "validate_budget_cas_max_retries/1 fails closed outside the bounded range" do
      assert {:error, :invalid_config} = Config.validate_budget_cas_max_retries(-1)
      assert {:error, :invalid_config} = Config.validate_budget_cas_max_retries(21)
      assert {:error, :invalid_config} = Config.validate_budget_cas_max_retries(1.0)
    end
  end

  describe "speech output acceptance timeout (VP-04E2R1)" do
    @tag spec: "VOICE-13"
    test "literal default is 100 ms and ceiling is 250 ms" do
      assert Config.default_speech_output_timeout_ms() == 100
      assert Config.max_speech_output_timeout_ms() == 250
    end

    @tag spec: "VOICE-13"
    test "validate_speech_output_timeout_ms/1 accepts 1, default, and 250" do
      assert {:ok, 1} = Config.validate_speech_output_timeout_ms(1)
      assert {:ok, 100} = Config.validate_speech_output_timeout_ms(100)
      assert {:ok, 250} = Config.validate_speech_output_timeout_ms(250)

      assert {:ok, 100} =
               Config.validate_speech_output_timeout_ms(Config.default_speech_output_timeout_ms())
    end

    @tag spec: "VOICE-13"
    test "validate_speech_output_timeout_ms/1 fails closed on zero, above-ceiling, and malformed" do
      for bad <- [0, -1, 251, 251.0, 1.5, "100", nil, :ms, true, %{}] do
        assert {:error, :invalid_config} = Config.validate_speech_output_timeout_ms(bad)
      end
    end

    @tag spec: "VOICE-13"
    test "speech_output_timeout_ms/0 resolves to the validated default under checked-in config" do
      assert Config.speech_output_timeout_ms() ==
               Config.validate_speech_output_timeout_ms(Config.default_speech_output_timeout_ms())
    end
  end

  describe "tool router timeout (VP-04E3)" do
    @tag spec: "VOICE-8"
    test "literal default is 5000 ms and ceiling is 30000 ms" do
      assert Config.default_tool_router_timeout_ms() == 5_000
      assert Config.max_tool_router_timeout_ms() == 30_000
    end

    @tag spec: "VOICE-8"
    test "validate_tool_router_timeout_ms/1 accepts 1, default, and 30000" do
      assert {:ok, 1} = Config.validate_tool_router_timeout_ms(1)
      assert {:ok, 5_000} = Config.validate_tool_router_timeout_ms(5_000)
      assert {:ok, 30_000} = Config.validate_tool_router_timeout_ms(30_000)
    end

    @tag spec: "VOICE-8"
    test "validate_tool_router_timeout_ms/1 fails closed on zero, above-ceiling, and malformed" do
      for bad <- [0, -1, 30_001, 1.5, "5000", nil, :ms, true, %{}] do
        assert {:error, :invalid_config} = Config.validate_tool_router_timeout_ms(bad)
      end
    end

    @tag spec: "VOICE-8"
    test "tool_router_timeout_ms/0 resolves to the validated default under checked-in config" do
      assert Config.tool_router_timeout_ms() ==
               Config.validate_tool_router_timeout_ms(Config.default_tool_router_timeout_ms())
    end
  end
end
