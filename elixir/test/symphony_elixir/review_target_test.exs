defmodule SymphonyElixir.ReviewTargetTest do
  use ExUnit.Case

  alias SymphonyElixir.ReviewTarget

  @head_sha String.duplicate("a", 40)
  @other_head_sha String.duplicate("b", 40)

  test "target identity includes repository, pull request number, and head sha" do
    assert {:ok, target} =
             ReviewTarget.new(%{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               head_sha: @head_sha
             })

    assert ReviewTarget.identity(target) == %{
             repository: "aroakpm-svg/symphony",
             pull_request_number: 25,
             head_sha: @head_sha
           }

    assert ReviewTarget.key(target) == "aroakpm-svg/symphony#25@#{@head_sha}"
  end

  test "same pull request number in different repositories cannot share identity or dedup" do
    assert {:ok, symphony_target} =
             ReviewTarget.new(%{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               head_sha: @head_sha
             })

    assert {:ok, central_brain_target} =
             ReviewTarget.new(%{
               repository: "aroakpm-svg/aroak-central-brain",
               pull_request_number: 25,
               head_sha: @head_sha
             })

    refute ReviewTarget.key(symphony_target) == ReviewTarget.key(central_brain_target)

    refute ReviewTarget.dedup_key(symphony_target, :review_request, :codex) ==
             ReviewTarget.dedup_key(central_brain_target, :review_request, :codex)
  end

  test "same repository and pull request with a new head is a new target" do
    assert {:ok, old_target} =
             ReviewTarget.new(%{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               head_sha: @head_sha
             })

    assert {:ok, new_target} =
             ReviewTarget.new(%{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               head_sha: @other_head_sha
             })

    refute ReviewTarget.key(old_target) == ReviewTarget.key(new_target)
  end

  test "malformed or incomplete targets fail closed" do
    assert {:error, :invalid_review_target} = ReviewTarget.new(:not_a_map)
    assert {:error, _reason} = ReviewTarget.new(%{repository: "symphony", pull_request_number: 25, head_sha: @head_sha})
    assert {:error, _reason} = ReviewTarget.new(%{repository: "aroakpm-svg/symphony", pull_request_number: 0, head_sha: @head_sha})
    assert {:error, _reason} = ReviewTarget.new(%{repository: "aroakpm-svg/symphony", pull_request_number: 25, head_sha: "short"})
    assert {:error, _reason} = ReviewTarget.new(%{repository: 42, pull_request_number: 25, head_sha: @head_sha})
    assert {:error, _reason} = ReviewTarget.new(%{repository: "aroakpm-svg/symphony", pull_request_number: "25", head_sha: @head_sha})
    assert {:error, _reason} = ReviewTarget.new(%{repository: "aroakpm-svg/symphony", pull_request_number: 25, head_sha: 42})

    assert {:error, :review_target_allowlist_empty} = ReviewTarget.validate_all([])
    assert {:error, :review_target_allowlist_invalid} = ReviewTarget.validate_all(:not_a_list)

    assert {:error, {:invalid_review_target, _reason}} =
             ReviewTarget.validate_all([%{repository: "symphony", pull_request_number: 25, head_sha: @head_sha}])
  end

  test "snapshot must match the immutable target identity" do
    assert {:ok, target} =
             ReviewTarget.new(%{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               head_sha: @head_sha
             })

    assert :ok =
             ReviewTarget.assert_snapshot(target, %{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               current_head_sha: @head_sha
             })

    assert {:error, {:target_identity_mismatch, :repository, _expected, _actual}} =
             ReviewTarget.assert_snapshot(target, %{
               repository: "aroakpm-svg/aroak-central-brain",
               pull_request_number: 25,
               current_head_sha: @head_sha
             })

    assert {:error, {:target_identity_mismatch, :head_sha, _expected, _actual}} =
             ReviewTarget.assert_snapshot(target, %{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               current_head_sha: @other_head_sha
             })

    assert {:error, :invalid_review_snapshot} = ReviewTarget.assert_snapshot(target, :not_a_map)
  end

  test "struct validation fails closed for non-binary identity fields" do
    assert {:error, {:invalid_repository, 42}} =
             ReviewTarget.new(%ReviewTarget{repository: 42, pull_request_number: 25, head_sha: @head_sha})

    assert {:error, {:invalid_pull_request_number, "25"}} =
             ReviewTarget.new(%ReviewTarget{
               repository: "aroakpm-svg/symphony",
               pull_request_number: "25",
               head_sha: @head_sha
             })

    assert {:error, {:invalid_head_sha, 42}} =
             ReviewTarget.new(%ReviewTarget{
               repository: "aroakpm-svg/symphony",
               pull_request_number: 25,
               head_sha: 42
             })
  end
end
