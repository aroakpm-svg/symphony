defmodule SymphonyElixir.MultiProjectPollTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Linear.Issue, MultiProjectPoll}

  test "keeps each successful profile's candidates in stable profile order" do
    profiles = [profile("central-brain"), profile("project-management")]

    fetcher = fn
      %{key: "central-brain"} -> {:ok, [issue("one", "central-id")]}
      %{key: "project-management"} -> {:ok, [issue("two", "pm-id")]}
    end

    assert %{candidates: candidates, outcomes: outcomes, ambiguous_issue_ids: ambiguous_issue_ids} =
             MultiProjectPoll.fetch(profiles, fetcher)

    assert Enum.map(candidates, & &1.id) == ["one", "two"]
    assert Enum.map(candidates, & &1.project_profile.key) == ["central-brain", "project-management"]
    assert outcomes == %{"central-brain" => %{status: :ok}, "project-management" => %{status: :ok}}
    assert ambiguous_issue_ids == MapSet.new()
  end

  test "retains a successful profile when another profile times out" do
    profiles = [profile("central-brain"), profile("project-management")]

    fetcher = fn
      %{key: "central-brain"} -> Process.sleep(100)
      %{key: "project-management"} -> {:ok, [issue("two", "pm-id")]}
    end

    assert %{candidates: candidates, outcomes: outcomes} =
             MultiProjectPoll.fetch(profiles, fetcher, timeout: 10)

    assert Enum.map(candidates, & &1.id) == ["two"]
    assert outcomes["central-brain"] == %{status: :timeout, retry: :transient}
    assert outcomes["project-management"] == %{status: :ok}
  end

  test "retains a successful profile when another profile fetcher raises" do
    profiles = [profile("central-brain"), profile("project-management")]

    fetcher = fn
      %{key: "central-brain"} -> raise "unexpected profile fetch failure"
      %{key: "project-management"} -> {:ok, [issue("two", "pm-id")]}
    end

    assert %{candidates: candidates, outcomes: outcomes} = MultiProjectPoll.fetch(profiles, fetcher)

    assert Enum.map(candidates, & &1.id) == ["two"]
    assert outcomes["central-brain"] == %{status: :error, retry: :transient}
    assert outcomes["project-management"] == %{status: :ok}
  end

  test "retains a successful profile when another profile fetcher exits" do
    profiles = [profile("central-brain"), profile("project-management")]

    fetcher = fn
      %{key: "central-brain"} -> exit(:unexpected_profile_fetch_exit)
      %{key: "project-management"} -> {:ok, [issue("two", "pm-id")]}
    end

    assert %{candidates: candidates, outcomes: outcomes} = MultiProjectPoll.fetch(profiles, fetcher)

    assert Enum.map(candidates, & &1.id) == ["two"]
    assert outcomes["central-brain"] == %{status: :error, retry: :transient}
    assert outcomes["project-management"] == %{status: :ok}
  end

  test "excludes candidates with a UUID returned by multiple profiles" do
    profiles = [profile("central-brain"), profile("project-management")]

    fetcher = fn
      %{key: "central-brain"} -> {:ok, [issue("duplicate", "central-id")]}
      %{key: "project-management"} -> {:ok, [issue("duplicate", "pm-id")]}
    end

    assert %{candidates: [], ambiguous_issue_ids: ambiguous_issue_ids} =
             MultiProjectPoll.fetch(profiles, fetcher)

    assert ambiguous_issue_ids == MapSet.new(["duplicate"])
  end

  test "deduplicates a repeated UUID from one profile without marking it ambiguous" do
    profiles = [profile("central-brain"), profile("project-management")]

    fetcher = fn
      %{key: "central-brain"} ->
        {:ok, [issue("repeated", "central-id"), issue("repeated", "central-id")]}

      %{key: "project-management"} ->
        {:ok, []}
    end

    assert %{candidates: candidates, ambiguous_issue_ids: ambiguous_issue_ids} =
             MultiProjectPoll.fetch(profiles, fetcher)

    assert Enum.map(candidates, &{&1.id, &1.project_profile.key}) == [
             {"repeated", "central-brain"}
           ]

    assert ambiguous_issue_ids == MapSet.new()
  end

  test "classifies fetch failures without retaining secret error contents" do
    profiles = [profile("central-brain"), profile("project-management")]

    fetcher = fn
      %{key: "central-brain"} -> {:error, {:linear_api_request, "token=must-not-leak"}}
      %{key: "project-management"} -> {:ok, [issue("two", "pm-id")]}
    end

    assert %{candidates: candidates, outcomes: outcomes} = MultiProjectPoll.fetch(profiles, fetcher)

    assert Enum.map(candidates, & &1.id) == ["two"]

    assert outcomes == %{
             "central-brain" => %{status: :error, retry: :transient},
             "project-management" => %{status: :ok}
           }

    refute inspect(outcomes) =~ "token=must-not-leak"
  end

  defp profile(key), do: %{key: key, linear_project_id: "#{key}-linear-id"}

  defp issue(id, project_id), do: %Issue{id: id, project_id: project_id}
end
