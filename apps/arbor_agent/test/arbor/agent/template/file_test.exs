defmodule Arbor.Agent.Template.FileTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Template.File, as: TemplateFile

  # Post-B2 (data-first): the shipped `.md` files in `priv/templates/` ARE the
  # source of truth — there are no longer any per-persona modules. The fidelity
  # guarantee is now: every shipped `.md` parses, validates, and round-trips
  # (parse -> serialize -> parse) byte-stably, ignoring only the volatile
  # created_at/updated_at timestamps.
  @shipped_md_paths Path.wildcard(
                      Path.join([
                        :code.priv_dir(:arbor_agent) |> to_string(),
                        "templates",
                        "*.md"
                      ])
                    )

  @volatile ~w(created_at updated_at)

  test "there are shipped builtin .md files to exercise" do
    assert length(@shipped_md_paths) >= 10
  end

  describe "parse/1 + serialize/1 round-trip (shipped .md)" do
    for path <- @shipped_md_paths do
      name = path |> Path.basename(".md")

      test "round-trips #{name} losslessly" do
        content = File.read!(unquote(path))

        assert {:ok, data} = TemplateFile.parse(content)

        # serialize -> parse must reproduce the same data map.
        assert {:ok, reparsed} = TemplateFile.parse(TemplateFile.serialize(data))

        assert Map.drop(reparsed, @volatile) == Map.drop(data, @volatile),
               "round-trip mismatch for #{unquote(name)}"
      end
    end
  end

  describe "validate/1" do
    for path <- @shipped_md_paths do
      name = path |> Path.basename(".md")

      test "validates shipped #{name}" do
        {:ok, data} = TemplateFile.parse(File.read!(unquote(path)))
        assert :ok = TemplateFile.validate(data)

        # also valid after a round-trip
        {:ok, parsed} = TemplateFile.parse(TemplateFile.serialize(data))
        assert :ok = TemplateFile.validate(parsed)
      end
    end

    test "rejects a missing character name" do
      data = %{
        "character" => %{},
        "initial_goals" => [],
        "required_capabilities" => []
      }

      assert {:error, reasons} = TemplateFile.validate(data)
      assert {:character, :missing_name} in reasons
    end

    test "rejects malformed goals and capabilities" do
      data = %{
        "character" => %{"name" => "X"},
        "initial_goals" => [%{"type" => "achieve"}],
        "required_capabilities" => [%{"description" => "no resource"}]
      }

      assert {:error, reasons} = TemplateFile.validate(data)
      assert Enum.any?(reasons, &match?({:initial_goals, _}, &1))
      assert Enum.any?(reasons, &match?({:required_capabilities, _}, &1))
    end
  end
end
