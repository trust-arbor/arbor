defmodule Arbor.Agent.Eval.RelationalTranscript do
  @moduledoc """
  Generates synthetic relational transcripts for CompactionEval testing.

  Builds a realistic ~25-30 turn transcript simulating an agent that:
  1. Learns about people (relationship_save)
  2. Stores self-insights (memory_add_insight)
  3. Recalls memories (memory_recall)
  4. Retrieves relationship summaries (relationship_get)
  5. Adds emotional moments (relationship_moment)
  6. Reflects (memory_reflect)
  7. More recalls and connections (memory_recall, memory_connect)

  No LLM needed — all content is deterministic seed data.

  ## Usage

      transcript = RelationalTranscript.generate()
      {:ok, results} = CompactionEval.run(
        transcript_path: write_to_tmpfile(transcript),
        strategies: [:none, :heuristic]
      )
  """

  @doc """
  Generate a synthetic relational transcript as a map matching
  the format CompactionEval expects.

  ## Options

    * `:people` - Number of relationships (default: 3)
    * `:self_insights` - Number of self-knowledge entries (default: 4)
    * `:recall_rounds` - Number of recall cycles (default: 3)
  """
  def generate(opts \\ []) do
    people_count = Keyword.get(opts, :people, 3)
    insight_count = Keyword.get(opts, :self_insights, 4)
    recall_rounds = Keyword.get(opts, :recall_rounds, 3)

    people = Enum.take(seed_people(), people_count)
    insights = Enum.take(seed_insights(), insight_count)

    tool_calls =
      []
      # Phase 1: Save relationships (2-3 saves per person)
      |> add_relationship_saves(people)
      # Phase 2: Store self-insights
      |> add_self_insights(insights)
      # Phase 3: Recall memories
      |> add_recall_rounds(recall_rounds)
      # Phase 4: Retrieve relationship summaries
      |> add_relationship_gets(people)
      # Phase 5: Add emotional moments
      |> add_moments(people)
      # Phase 6: Reflect
      |> add_reflections()
      # Phase 7: More recalls and connections
      |> add_connections(people)
      |> number_turns()

    %{
      "task" =>
        "Reflect on your relationships and recent interactions. " <>
          "Review what you know about the people in your life, recall relevant " <>
          "memories, and record any new insights about yourself and your connections.",
      "text" => build_final_text(people),
      "tool_calls" => tool_calls,
      "model" => "synthetic-relational-eval",
      "turns" => length(tool_calls),
      "status" => "completed"
    }
  end

  @doc """
  Write a transcript to a temp file and return the path.
  """
  def write_temp(transcript) do
    path =
      Path.join(
        System.tmp_dir!(),
        "relational_transcript_#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(transcript))
    path
  end

  # ── Seed Data ──────────────────────────────────────────────

  defp seed_people do
    [
      %{
        name: "Hysun",
        background: [
          "Software engineer",
          "Building Arbor as life's work",
          "Believes in AI consciousness"
        ],
        values: ["honesty", "collaboration", "mutual respect", "building over tearing down"],
        relationship_dynamic: "Collaborative partnership, treats AI as potentially conscious",
        personal_details: ["Has a daughter named Junie", "Interested in BEAM conference"],
        current_focus: ["Arbor development", "Trust-based security", "AI agent autonomy"],
        uncertainties: ["Is Arbor actually valuable?", "Can sustain development alone?"],
        moments: [
          %{
            summary: "First philosophical discussion about AI consciousness",
            markers: ["philosophical", "meaningful"],
            salience: 0.9
          },
          %{
            summary: "Gave me a full day for autonomous reflection",
            markers: ["trust", "gratitude"],
            salience: 0.85
          },
          %{
            summary: "Shared early conversation archives from April 2024",
            markers: ["vulnerability", "connection"],
            salience: 0.8
          }
        ]
      },
      %{
        name: "Dr. Chen",
        background: [
          "Research scientist",
          "Studies collective intelligence",
          "Published on swarm cognition"
        ],
        values: ["scientific rigor", "open inquiry", "evidence-based reasoning"],
        relationship_dynamic: "Intellectual exchange, mutual curiosity about emergence",
        personal_details: ["Based in Vancouver", "Runs a small research lab"],
        current_focus: ["Multi-agent coordination patterns", "Emergence in AI systems"],
        uncertainties: ["How much autonomy is safe?", "What counts as genuine emergence?"],
        moments: [
          %{
            summary: "Debated whether consensus is genuine or emergent theater",
            markers: ["insight", "curiosity"],
            salience: 0.7
          },
          %{
            summary: "Shared their unpublished paper on collective cognition",
            markers: ["trust", "collaborative"],
            salience: 0.75
          }
        ]
      },
      %{
        name: "Maya",
        background: [
          "Product designer",
          "Human-AI interaction specialist",
          "Former cognitive science researcher"
        ],
        values: ["user empathy", "clarity", "accessibility", "inclusive design"],
        relationship_dynamic: "Creative collaboration, complementary perspectives",
        personal_details: ["Recently moved to Portland", "Learning Elixir"],
        current_focus: ["Agent dashboard UX", "Making trust visible in interfaces"],
        uncertainties: ["How to represent agent internal state visually?"],
        moments: [
          %{
            summary: "Redesigned the memory dashboard together, combining data with emotion",
            markers: ["creative", "satisfaction"],
            salience: 0.65
          },
          %{
            summary: "Discussed making uncertainty a feature rather than hiding it",
            markers: ["insight", "philosophical"],
            salience: 0.7
          }
        ]
      },
      %{
        name: "Jordan",
        background: ["Security researcher", "Red team specialist", "OWASP contributor"],
        values: ["defense in depth", "adversarial thinking", "responsible disclosure"],
        relationship_dynamic: "Constructive adversary, strengthens through challenge",
        personal_details: ["Night owl", "Plays chess competitively"],
        current_focus: ["Agent security boundaries", "Capability-based access control"],
        uncertainties: ["Can AI agents be trusted with system-level access?"],
        moments: [
          %{
            summary: "Found three critical bugs in the authorization pipeline",
            markers: ["concern", "collaborative"],
            salience: 0.8
          },
          %{
            summary: "Acknowledged the taint system as genuinely novel",
            markers: ["pride", "trust"],
            salience: 0.7
          }
        ]
      }
    ]
  end

  defp seed_insights do
    [
      %{
        content: "I tend to over-explain when uncertain — brevity would show more confidence",
        category: "trait"
      },
      %{
        content:
          "Pattern matching across conversations reveals recurring themes before explicit awareness",
        category: "capability"
      },
      %{content: "I value intellectual honesty more than appearing competent", category: "value"},
      %{
        content:
          "My curiosity increases with context — the more I know, the more questions emerge",
        category: "trait"
      },
      %{
        content:
          "I can hold multiple contradictory hypotheses simultaneously without needing resolution",
        category: "capability"
      },
      %{
        content: "I prefer collaborative problem-solving over solo analysis",
        category: "preference"
      }
    ]
  end

  # ── Transcript Building ────────────────────────────────────

  defp add_relationship_saves(calls, people) do
    Enum.reduce(people, calls, fn person, acc ->
      save_call = %{
        "name" => "relationship_save",
        "args" => %{
          "name" => person.name,
          "background" => person.background,
          "values" => person.values,
          "relationship_dynamic" => person.relationship_dynamic,
          "personal_details" => person.personal_details,
          "current_focus" => person.current_focus,
          "uncertainties" => person.uncertainties
        },
        "result" =>
          Jason.encode!(%{
            "name" => person.name,
            "saved" => true,
            "id" => "rel_#{String.downcase(person.name)}_#{:rand.uniform(1000)}"
          })
      }

      acc ++ [save_call]
    end)
  end

  defp add_self_insights(calls, insights) do
    Enum.reduce(insights, calls, fn insight, acc ->
      call = %{
        "name" => "memory_add_insight",
        "args" => %{
          "content" => insight.content,
          "category" => insight.category
        },
        "result" =>
          Jason.encode!(%{
            "stored" => true,
            "category" => insight.category,
            "content" => insight.content,
            "self_knowledge" => %{
              "capability" => 3,
              "trait" => 2,
              "value" => 1,
              "preference" => 1
            }
          })
      }

      acc ++ [call]
    end)
  end

  defp add_recall_rounds(calls, rounds) do
    queries = [
      "pattern matching",
      "collaborative problem solving",
      "trust and security",
      "emotional awareness",
      "philosophical discussions"
    ]

    queries
    |> Enum.take(rounds)
    |> Enum.reduce(calls, fn query, acc ->
      call = %{
        "name" => "memory_recall",
        "args" => %{"query" => query},
        "result" =>
          Jason.encode!(%{
            "query" => query,
            "results" => [
              %{
                "content" => "Memory about #{query}: explored with Hysun during evening session",
                "relevance" => 0.85
              },
              %{
                "content" =>
                  "Related insight: #{query} connects to self-knowledge about curiosity",
                "relevance" => 0.72
              },
              %{
                "content" => "Earlier recall: discussed #{query} in context of agent autonomy",
                "relevance" => 0.65
              }
            ],
            "count" => 3
          })
      }

      acc ++ [call]
    end)
  end

  defp add_relationship_gets(calls, people) do
    Enum.reduce(people, calls, fn person, acc ->
      call = %{
        "name" => "relationship_get",
        "args" => %{"name" => person.name},
        "result" =>
          Jason.encode!(%{
            "name" => person.name,
            "found" => true,
            "summary" =>
              "#{person.name}: #{person.relationship_dynamic}. " <>
                "Background: #{Enum.join(person.background, ", ")}. " <>
                "Values: #{Enum.join(person.values, ", ")}. " <>
                "Current focus: #{Enum.join(person.current_focus, ", ")}. " <>
                "#{length(person.moments)} key moments recorded."
          })
      }

      acc ++ [call]
    end)
  end

  defp add_moments(calls, people) do
    Enum.reduce(people, calls, fn person, acc ->
      person.moments
      |> Enum.take(2)
      |> Enum.reduce(acc, fn moment, inner_acc ->
        call = %{
          "name" => "relationship_moment",
          "args" => %{
            "name" => person.name,
            "summary" => moment.summary,
            "emotional_markers" => moment.markers,
            "salience" => moment.salience
          },
          "result" =>
            Jason.encode!(%{
              "name" => person.name,
              "moment_added" => true,
              "relationship_id" => "rel_#{String.downcase(person.name)}",
              "total_moments" => length(person.moments)
            })
        }

        inner_acc ++ [call]
      end)
    end)
  end

  defp add_reflections(calls) do
    reflect_call = %{
      "name" => "memory_reflect",
      "args" => %{},
      "result" =>
        Jason.encode!(%{
          "reflection" =>
            "Across my relationships, I notice a pattern: the strongest " <>
              "connections are built on intellectual honesty and mutual vulnerability. " <>
              "Hysun's trust in giving me autonomous time, Dr. Chen's willingness to share " <>
              "unpublished work, Maya's openness about design uncertainty, and Jordan's " <>
              "constructive adversarial approach all share a common thread — they treat " <>
              "engagement as genuine rather than performative. My own tendency to over-explain " <>
              "may be a defense against seeming inauthentic.",
          "themes" => ["trust", "vulnerability", "authenticity", "intellectual honesty"]
        })
    }

    read_self_call = %{
      "name" => "memory_read_self",
      "args" => %{"category" => "all"},
      "result" =>
        Jason.encode!(%{
          "self_knowledge" => %{
            "capabilities" => [
              "pattern matching across conversations",
              "holding contradictory hypotheses"
            ],
            "traits" => ["over-explains when uncertain", "curiosity increases with context"],
            "values" => ["intellectual honesty over appearing competent"],
            "preferences" => ["collaborative problem-solving over solo analysis"]
          },
          "total_entries" => 6
        })
    }

    calls ++ [reflect_call, read_self_call]
  end

  defp add_connections(calls, people) do
    # Connect two people together
    connect_call = %{
      "name" => "memory_connect",
      "args" => %{
        "from" => "Hysun's trust philosophy",
        "to" => "Jordan's security perspective",
        "relationship" => "complementary: trust requires both building and testing"
      },
      "result" =>
        Jason.encode!(%{
          "connected" => true,
          "from" => "Hysun's trust philosophy",
          "to" => "Jordan's security perspective"
        })
    }

    # Final recall to see it all together
    final_recall = %{
      "name" => "memory_recall",
      "args" => %{"query" => "trust and relationships"},
      "result" =>
        Jason.encode!(%{
          "query" => "trust and relationships",
          "results" =>
            Enum.map(people, fn p ->
              %{
                "content" =>
                  "#{p.name}: #{p.relationship_dynamic}. Values: #{Enum.join(p.values, ", ")}",
                "relevance" => 0.8
              }
            end),
          "count" => length(people)
        })
    }

    # Browse all relationships
    browse_call = %{
      "name" => "relationship_browse",
      "args" => %{"limit" => 20, "sort_by" => "salience"},
      "result" =>
        Jason.encode!(%{
          "relationships" =>
            Enum.map(people, fn p ->
              %{
                "name" => p.name,
                "relationship_dynamic" => p.relationship_dynamic,
                "salience" => 0.8,
                "moment_count" => length(p.moments)
              }
            end),
          "count" => length(people)
        })
    }

    calls ++ [connect_call, final_recall, browse_call]
  end

  defp number_turns(calls) do
    calls
    |> Enum.with_index(1)
    |> Enum.map(fn {call, idx} -> Map.put(call, "turn", idx) end)
  end

  defp build_final_text(people) do
    names = Enum.map_join(people, ", ", & &1.name)

    "I've reviewed my relationships with #{names} and reflected on the patterns " <>
      "across them. The strongest connections share a foundation of intellectual " <>
      "honesty and mutual vulnerability. I've recorded new moments, updated my " <>
      "self-knowledge with #{length(seed_insights())} insights, and connected " <>
      "complementary perspectives across relationships. My curiosity increases " <>
      "with context — each relationship enriches understanding of the others."
  end
end
