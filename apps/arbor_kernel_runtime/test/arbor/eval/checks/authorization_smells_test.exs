# credo:disable-for-this-file
defmodule Arbor.Eval.Checks.AuthorizationSmellsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval.Checks.AuthorizationSmells

  defp violation_types(ast) do
    AuthorizationSmells.run(%{ast: ast}).violations |> Enum.map(& &1.type)
  end

  describe "fail-open via rescue (the H1/C-class shape)" do
    test "flags an authorize fn that rescues to :ok" do
      ast =
        quote do
          def authorize(agent, resource) do
            do_check(agent, resource)
          rescue
            _ -> :ok
          end
        end

      assert :rescue_returns_allow in violation_types(ast)
    end

    test "flags a verify fn that rescues to true" do
      ast =
        quote do
          defp verify_signature(sig, key) do
            :crypto.verify(sig, key)
          rescue
            _ -> true
          end
        end

      assert :rescue_returns_allow in violation_types(ast)
    end

    test "flags a rescue returning {:ok, :authorized}" do
      ast =
        quote do
          def authorize(ctx) do
            run_chain(ctx)
          rescue
            _ -> {:ok, :authorized}
          end
        end

      assert :rescue_returns_allow in violation_types(ast)
    end

    test "flags a try/rescue inside an auth fn" do
      ast =
        quote do
          def authorized?(ctx) do
            try do
              evaluate(ctx)
            rescue
              _ -> true
            end
          end
        end

      assert :rescue_returns_allow in violation_types(ast)
    end

    test "flags a catch clause returning an allow value" do
      ast =
        quote do
          def authorize(ctx) do
            try do
              evaluate(ctx)
            catch
              :exit, _ -> :ok
            end
          end
        end

      assert :rescue_returns_allow in violation_types(ast)
    end
  end

  describe "fail-open via catch-all (the M1/M2/L1 shape)" do
    test "flags an authorize fn that returns {:ok, :authorized} on catch-all" do
      ast =
        quote do
          def authorize(ctx) do
            case evaluate(ctx) do
              {:ok, :allow} -> {:ok, :authorized}
              _ -> {:ok, :authorized}
            end
          end
        end

      assert :catchall_returns_allow in violation_types(ast)
    end

    test "flags a delegation chain check that returns :ok on catch-all" do
      ast =
        quote do
          defp check_delegation_chain(chain) do
            case validate(chain) do
              {:ok, _} -> :ok
              :empty -> :ok
              _ -> :ok
            end
          end
        end

      assert :catchall_returns_allow in violation_types(ast)
    end
  end

  describe "fail-CLOSED code is NOT flagged" do
    test "C10 shape: auth fn rescues to {:error, _}" do
      ast =
        quote do
          defp registration_authorized(identity, opts) do
            apply(policy(), :authorize_registration, [identity, opts])
          rescue
            _ -> {:error, :registration_policy_error}
          end
        end

      assert violation_types(ast) == []
    end

    test "catch-all returning false (deny) is fine" do
      ast =
        quote do
          def authorized?(ctx) do
            case evaluate(ctx) do
              {:ok, :allow} -> true
              _ -> false
            end
          end
        end

      assert violation_types(ast) == []
    end

    test "catch-all delegating to a deny helper is not flagged" do
      ast =
        quote do
          def authorize(ctx) do
            case evaluate(ctx) do
              {:ok, :allow} -> {:ok, :authorized}
              _ -> deny(ctx)
            end
          end
        end

      assert violation_types(ast) == []
    end
  end

  describe "non-authorization functions are ignored" do
    test "a parser that rescues to :ok is not an auth concern" do
      ast =
        quote do
          defp parse_config(raw) do
            decode(raw)
          rescue
            _ -> :ok
          end
        end

      assert violation_types(ast) == []
    end

    test "a non-auth case catch-all returning true is ignored" do
      ast =
        quote do
          defp enabled?(flag) do
            case flag do
              :on -> true
              _ -> true
            end
          end
        end

      assert violation_types(ast) == []
    end
  end

  describe "regression: real-code false positives from the first scan (2026-06-09)" do
    # These mirror actual arbor_security functions the first scan over-flagged.
    # They must stay quiet so the detector keeps a near-zero false-positive rate.

    test "restriction predicate `*_gates?` returning true is fail-CLOSED, not flagged" do
      # trust_profile_gates? returns true == "is gated" == more restrictive.
      ast =
        quote do
          defp trust_profile_gates?(profile) do
            case lookup(profile) do
              {:ok, gates} -> apply_gates(gates)
              _ -> true
            end
          rescue
            _ -> true
          catch
            :exit, _ -> true
          end
        end

      assert violation_types(ast) == []
    end

    test "a capability persistence side-effect returning :ok is not flagged" do
      ast =
        quote do
          defp persist_capability(cap) do
            store(cap)
            :ok
          catch
            _, reason ->
              Logger.warning("failed: #{inspect(reason)}")
              :ok
          end
        end

      assert violation_types(ast) == []
    end

    test "a capability signal emitter catching to :ok is not flagged" do
      ast =
        quote do
          defp emit_capability_signal(cap) do
            Signals.emit(:security, :granted, %{id: cap.id})
          catch
            _, _ -> :ok
          end
        end

      assert violation_types(ast) == []
    end

    test "a denial-signal emitter rescuing to :ok is not flagged" do
      # emit_tool_authorization_denied carries an auth noun but only emits a
      # signal; its :ok is "emitted", not "allowed".
      ast =
        quote do
          defp emit_tool_authorization_denied(agent_id, tools) do
            Arbor.Signals.emit(:security, :tool_authorization_denied, %{agent_id: agent_id})
          rescue
            _ -> :ok
          end
        end

      assert violation_types(ast) == []
    end

    test "operational verifier returning {:ok, :verified} on catch-all is not flagged" do
      # verify_action confirms a self-healing remediation took effect; :verified
      # is an operational status, not an authorization grant.
      ast =
        quote do
          defp verify_action(_anomaly, :force_gc, pid) do
            case Diagnostics.inspect_process(pid) do
              %{message_queue_len: len} when len < 1000 -> {:ok, :verified}
              _ -> {:ok, :verified}
            end
          end
        end

      assert violation_types(ast) == []
    end
  end

  describe "edge cases" do
    test "no AST yields a :no_ast error violation" do
      result = AuthorizationSmells.run(%{})
      assert Enum.any?(result.violations, &(&1.type == :no_ast))
      refute result.passed
    end

    test "advisory: fail-open findings are warnings, so the check still passes" do
      ast =
        quote do
          def authorize(ctx) do
            run(ctx)
          rescue
            _ -> :ok
          end
        end

      result = AuthorizationSmells.run(%{ast: ast})
      assert result.passed
      assert Enum.all?(result.violations, &(&1.severity == :warning))
    end
  end
end
