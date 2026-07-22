defmodule SymphonyElixir.GitHubReviewClient do
  @moduledoc "Reads latest-head review evidence and requests Codex reviews through `gh`."

  @graphql """
  query SymphonyReviewConvergence($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        number
        headRefOid
        baseRefOid
        reviews(last: 100) {
          nodes {
            body
            state
            submittedAt
            commit { oid }
            author {
              login
              __typename
              ... on Organization { databaseId }
              ... on Bot { databaseId }
            }
          }
        }
        reviewThreads(first: 100, after: $endCursor) {
          nodes {
            isResolved
            id
            comments(first: 100) {
              nodes { body path url commit { oid } }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @thread_comments_graphql """
  query SymphonyReviewThreadComments($threadId: ID!, $endCursor: String) {
    node(id: $threadId) {
      ... on PullRequestReviewThread {
        comments(first: 100, after: $endCursor) {
          nodes { body path url commit { oid } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @trusted_reviewers [
    %{login: "chatgpt-codex-connector", type: "Organization", database_id: 261_883_814},
    %{login: "chatgpt-codex-connector", type: "Bot", database_id: 199_175_422},
    %{login: "chatgpt-codex-connector[bot]", type: "Bot", database_id: 199_175_422}
  ]
  @expected_checks [
    %{name: "make-all", app_slug: "github-actions", app_id: 15_368},
    %{name: "validate-pr-description", app_slug: "github-actions", app_id: 15_368}
  ]

  @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(repository, branch) when is_binary(repository) and is_binary(branch) do
    with {:ok, number} <- find_pull_request(repository, branch),
         {:ok, pull_request} <- fetch_pull_request(repository, number),
         {:ok, clean_reviewed_head} <-
           fetch_clean_review_comment(repository, number, pull_request["headRefOid"]),
         {:ok, checks} <- required_checks(repository, number, pull_request["headRefOid"]),
         {:ok, base_verification} <- verify_base_claims(repository, pull_request) do
      {:ok,
       pull_request
       |> normalize_snapshot(checks, base_verification, clean_reviewed_head)
       |> Map.put(:repository, repository)
       |> Map.put(:pull_request_number, number)}
    end
  end

  @spec request_review(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def request_review(repository, number, key) do
    body = "@codex review\n\ndedup-key: `#{key}`"

    case run(["pr", "comment", Integer.to_string(number), "--repo", repository, "--body", body]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec review_request_exists?(String.t(), pos_integer(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def review_request_exists?(repository, number, key) do
    case run(["api", "--paginate", "--slurp", "repos/#{repository}/issues/#{number}/comments"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, pages} when is_list(pages) ->
            {:ok,
             pages
             |> List.flatten()
             |> Enum.any?(&String.contains?(&1["body"] || "", "dedup-key: `#{key}`"))}

          {:ok, unexpected} ->
            {:error, {:invalid_issue_comments, unexpected}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec publish_status(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def publish_status(repository, head_sha, state, description, target_url \\ nil)
      when state in [:pending, :success, :failure, :error] do
    fields = [
      "state=#{state}",
      "context=Review Convergence Gate",
      "description=#{String.slice(description, 0, 140)}"
    ]

    fields = if is_binary(target_url), do: fields ++ ["target_url=#{target_url}"], else: fields
    args = ["api", "repos/#{repository}/statuses/#{head_sha}", "--method", "POST"] ++ Enum.flat_map(fields, &["-f", &1])

    case run(args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec normalize_no_required_checks_for_test(String.t()) :: {:ok, []} | {:error, term()}
  def normalize_no_required_checks_for_test(output), do: normalize_no_required_checks(output)

  @doc false
  @spec normalize_required_checks_for_test(String.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def normalize_required_checks_for_test(output, status), do: normalize_required_checks(output, status)

  @doc false
  @spec normalize_expected_checks_for_test(map()) :: {:ok, [map()]} | {:error, term()}
  def normalize_expected_checks_for_test(payload), do: normalize_expected_checks(payload)

  @doc false
  @spec merge_required_checks_for_test([map()], [map()]) :: [map()]
  def merge_required_checks_for_test(expected, protected), do: merge_required_checks(expected, protected)

  @doc false
  @spec merge_check_run_pages_for_test([map()]) :: {:ok, map()} | {:error, term()}
  def merge_check_run_pages_for_test(pages), do: merge_check_run_pages(pages)

  @doc false
  @spec accepted_review_for_test?(map(), String.t()) :: boolean()
  def accepted_review_for_test?(review, head_sha), do: accepted_review?(review, head_sha)

  @doc false
  @spec merge_pull_request_pages_for_test([map()]) :: {:ok, map()} | {:error, term()}
  def merge_pull_request_pages_for_test(pages), do: merge_pull_request_pages(pages)

  @doc false
  @spec merge_thread_comment_pages_for_test([map()]) :: {:ok, [map()]} | {:error, term()}
  def merge_thread_comment_pages_for_test(pages), do: merge_thread_comment_pages(pages)

  @doc false
  @spec normalize_threads_for_test([map()], String.t()) :: [map()]
  def normalize_threads_for_test(threads, head_sha), do: normalize_threads(threads, head_sha)

  @doc false
  @spec base_missing_paths_for_test([map()], String.t()) :: [String.t()]
  def base_missing_paths_for_test(threads, head_sha), do: base_missing_paths(threads, head_sha)

  @doc false
  @spec structural_risk_for_test?([map()], String.t()) :: boolean()
  def structural_risk_for_test?(threads, head_sha), do: structural_risk?(threads, head_sha)

  @doc false
  @spec pull_request_query_for_test() :: String.t()
  def pull_request_query_for_test, do: @graphql

  @doc false
  @spec accepted_clean_comment_for_test?(map(), String.t(), String.t()) :: boolean()
  def accepted_clean_comment_for_test?(comment, head_sha, resolved_sha) do
    accepted_clean_comment?(comment, head_sha, resolved_sha)
  end

  @doc false
  @spec missing_paths_verified_for_test?(MapSet.t(String.t()), [String.t()]) :: boolean()
  def missing_paths_verified_for_test?(base_paths, claimed_missing_paths) do
    missing_paths_verified?(base_paths, claimed_missing_paths)
  end

  @doc false
  @spec base_tree_oid_for_test(map()) :: {:ok, String.t()} | {:error, term()}
  def base_tree_oid_for_test(payload), do: base_tree_oid(payload)

  defp find_pull_request(repository, branch) do
    args = [
      "pr",
      "list",
      "--repo",
      repository,
      "--state",
      "open",
      "--head",
      branch,
      "--json",
      "number"
    ]

    with {:ok, output} <- run(args),
         {:ok, [%{"number" => number} | _]} <- Jason.decode(output) do
      {:ok, number}
    else
      {:ok, []} -> {:error, :pull_request_not_found}
      {:ok, unexpected} -> {:error, {:invalid_pull_request_lookup, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_clean_review_comment(repository, number, head_sha) do
    args = [
      "api",
      "--paginate",
      "--slurp",
      "repos/#{repository}/issues/#{number}/comments?per_page=100"
    ]

    with {:ok, output} <- run(args),
         {:ok, pages} when is_list(pages) <- Jason.decode(output) do
      pages
      |> List.flatten()
      |> Enum.reverse()
      |> Enum.filter(&clean_review_comment?/1)
      |> resolve_clean_review_comments(repository, head_sha)
    else
      {:ok, payload} -> {:error, {:invalid_issue_comments, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_clean_review_comments(comments, repository, head_sha) do
    Enum.reduce_while(comments, {:ok, nil}, fn comment, _acc ->
      prefix = clean_review_prefix(comment["body"] || "")

      case resolve_commit_sha(repository, prefix) do
        {:ok, ^head_sha} -> {:halt, {:ok, head_sha}}
        {:ok, _other_sha} -> {:cont, {:ok, nil}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_commit_sha(repository, prefix) when is_binary(prefix) do
    case run(["api", "repos/#{repository}/commits/#{prefix}", "--jq", ".sha"]) do
      {:ok, output} ->
        sha = String.trim(output)
        if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: {:ok, sha}, else: {:error, {:invalid_commit_sha, sha}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clean_review_comment?(comment) do
    trusted_rest_reviewer?(comment["user"]) and is_binary(clean_review_prefix(comment["body"] || ""))
  end

  defp clean_review_prefix(body) do
    clean_result =
      String.contains?(body, "No major issues found") or
        String.contains?(body, "Didn't find any major issues")

    if clean_result do
      case Regex.run(~r/\*\*Reviewed commit:\*\* `([0-9a-f]{7,40})`/i, body, capture: :all_but_first) do
        [prefix] -> String.downcase(prefix)
        _ -> nil
      end
    end
  end

  defp accepted_clean_comment?(comment, head_sha, resolved_sha) do
    clean_review_comment?(comment) and resolved_sha == head_sha
  end

  defp fetch_pull_request(repository, number) do
    [owner, name] = String.split(repository, "/", parts: 2)

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{@graphql}",
      "-F",
      "owner=#{owner}",
      "-F",
      "name=#{name}",
      "-F",
      "number=#{number}",
      "--paginate",
      "--slurp"
    ]

    with {:ok, output} <- run(args),
         {:ok, decoded} when is_list(decoded) <- Jason.decode(output),
         {:ok, pull_request} <- merge_pull_request_pages(decoded),
         {:ok, pull_request} <- hydrate_pull_request_threads(repository, pull_request) do
      {:ok, pull_request}
    else
      nil -> {:error, :pull_request_not_found}
      {:ok, unexpected} -> {:error, {:invalid_pull_request_payload, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_checks(repository, pull_request_number, head_sha) do
    with {:ok, output} <-
           run([
             "api",
             "--paginate",
             "--slurp",
             "repos/#{repository}/commits/#{head_sha}/check-runs?per_page=100",
             "-H",
             "Accept: application/vnd.github+json"
           ]),
         {:ok, pages} when is_list(pages) <- Jason.decode(output),
         {:ok, payload} <- merge_check_run_pages(pages),
         {:ok, expected} <- normalize_expected_checks(payload),
         {:ok, protected} <- protected_required_checks(repository, pull_request_number) do
      {:ok, merge_required_checks(expected, protected)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp protected_required_checks(repository, pull_request_number) do
    args = [
      "pr",
      "checks",
      Integer.to_string(pull_request_number),
      "--repo",
      repository,
      "--required",
      "--json",
      "name,bucket,state,link"
    ]

    {output, status} = run_with_status(args)
    normalize_required_checks(String.trim(output), status)
  rescue
    error -> {:error, {:command_error, Exception.message(error)}}
  end

  defp merge_required_checks(expected, protected) do
    (expected ++ protected)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, checks} ->
      %{
        name: name,
        state: checks |> Enum.map(& &1.state) |> Enum.max_by(&check_state_rank/1),
        link: Enum.find_value(checks, & &1.link)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp check_state_rank(:failure), do: 5
  defp check_state_rank(:missing), do: 4
  defp check_state_rank(:pending), do: 3
  defp check_state_rank(:neutral), do: 2
  defp check_state_rank(:skipped), do: 1
  defp check_state_rank(:success), do: 0
  defp check_state_rank(_state), do: 5

  defp normalize_expected_checks(%{"check_runs" => runs}) when is_list(runs) do
    checks =
      Enum.map(@expected_checks, fn expected ->
        run =
          Enum.find(runs, fn candidate ->
            candidate["name"] == expected.name and
              get_in(candidate, ["app", "slug"]) == expected.app_slug and
              get_in(candidate, ["app", "id"]) == expected.app_id
          end)

        %{
          name: expected.name,
          state: check_run_state(run),
          link: run && run["details_url"]
        }
      end)

    {:ok, checks}
  end

  defp normalize_expected_checks(payload), do: {:error, {:invalid_check_runs, payload}}

  defp merge_check_run_pages(pages) when is_list(pages) do
    Enum.reduce_while(pages, {:ok, []}, fn
      %{"check_runs" => runs}, {:ok, acc} when is_list(runs) -> {:cont, {:ok, [runs | acc]}}
      payload, _acc -> {:halt, {:error, {:invalid_check_runs, payload}}}
    end)
    |> case do
      {:ok, pages_reversed} -> {:ok, %{"check_runs" => pages_reversed |> Enum.reverse() |> List.flatten()}}
      error -> error
    end
  end

  defp merge_check_run_pages(payload), do: {:error, {:invalid_check_run_pages, payload}}

  defp check_run_state(nil), do: :missing

  defp check_run_state(%{"status" => "completed", "conclusion" => conclusion}),
    do: normalize_check_state(conclusion)

  defp check_run_state(_run), do: :pending

  defp normalize_required_checks(output, status) do
    case Jason.decode(output) do
      {:ok, checks} when is_list(checks) ->
        {:ok,
         checks
         |> Enum.reject(&(&1["name"] == "Review Convergence Gate"))
         |> Enum.map(fn check ->
           %{
             name: check["name"],
             state: normalize_check_state(check["bucket"] || check["state"]),
             link: check["link"]
           }
         end)}

      {:error, _reason} when status == 1 ->
        normalize_no_required_checks(output)

      {:ok, unexpected} ->
        {:error, {:invalid_required_checks, unexpected}}

      {:error, reason} ->
        {:error, {:command_failed, status, reason}}
    end
  end

  defp merge_pull_request_pages(pages) do
    pull_requests = Enum.map(pages, &get_in(&1, ["data", "repository", "pullRequest"]))

    case pull_requests do
      [first | _] when is_map(first) ->
        threads = Enum.flat_map(pull_requests, &(get_in(&1 || %{}, ["reviewThreads", "nodes"]) || []))
        {:ok, put_in(first, ["reviewThreads", "nodes"], threads)}

      _ ->
        {:error, :pull_request_not_found}
    end
  end

  defp hydrate_pull_request_threads(repository, pull_request) do
    threads = get_in(pull_request, ["reviewThreads", "nodes"]) || []

    Enum.reduce_while(threads, {:ok, []}, fn thread, {:ok, acc} ->
      case hydrate_one_thread(repository, thread) do
        {:ok, hydrated} -> {:cont, {:ok, [hydrated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hydrated_reversed} ->
        {:ok, put_in(pull_request, ["reviewThreads", "nodes"], Enum.reverse(hydrated_reversed))}

      error ->
        error
    end
  end

  defp hydrate_one_thread(repository, thread) do
    comments = get_in(thread, ["comments", "nodes"]) || []

    if length(comments) == 100 do
      fetch_all_thread_comments(repository, thread["id"])
      |> case do
        {:ok, comments} -> {:ok, put_in(thread, ["comments", "nodes"], comments)}
        error -> error
      end
    else
      {:ok, thread}
    end
  end

  defp fetch_all_thread_comments(_repository, thread_id) when is_binary(thread_id) do
    args = [
      "api",
      "graphql",
      "-f",
      "query=#{@thread_comments_graphql}",
      "-F",
      "threadId=#{thread_id}",
      "--paginate",
      "--slurp"
    ]

    with {:ok, output} <- run(args),
         {:ok, pages} when is_list(pages) <- Jason.decode(output),
         {:ok, comments} <- merge_thread_comment_pages(pages) do
      {:ok, comments}
    else
      {:ok, payload} -> {:error, {:invalid_thread_comment_pages, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_all_thread_comments(_repository, thread_id), do: {:error, {:missing_review_thread_id, thread_id}}

  defp merge_thread_comment_pages(pages) when is_list(pages) do
    Enum.reduce_while(pages, {:ok, []}, fn page, {:ok, acc} ->
      case get_in(page, ["data", "node", "comments", "nodes"]) do
        nodes when is_list(nodes) -> {:cont, {:ok, [nodes | acc]}}
        _ -> {:halt, {:error, {:invalid_thread_comment_page, page}}}
      end
    end)
    |> case do
      {:ok, pages_reversed} -> {:ok, pages_reversed |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp merge_thread_comment_pages(payload), do: {:error, {:invalid_thread_comment_pages, payload}}

  defp normalize_no_required_checks(output) do
    if output == "" or String.contains?(output, "checks reported on") do
      {:ok, []}
    else
      {:error, {:command_failed, 1, output}}
    end
  end

  defp verify_base_claims(repository, pull_request) do
    threads = current_head_threads(pull_request)
    head_sha = pull_request["headRefOid"]
    paths = base_missing_paths(threads, head_sha)
    claim_present = base_missing_claim?(threads, head_sha)

    if claim_present do
      verify_claimed_base_paths(repository, pull_request["baseRefOid"], paths)
    else
      {:ok, %{required: false, result: :not_required}}
    end
  end

  defp verify_claimed_base_paths(_repository, _base_oid, []) do
    {:ok, %{required: true, result: :unverified}}
  end

  defp verify_claimed_base_paths(repository, base_oid, paths) do
    case fetch_base_tree_paths(repository, base_oid) do
      {:ok, base_paths} ->
        result = if missing_paths_verified?(base_paths, paths), do: :verified, else: :unverified
        {:ok, %{required: true, result: result}}

      {:error, _reason} ->
        {:ok, %{required: true, result: :unverified}}
    end
  end

  defp fetch_base_tree_paths(repository, base_oid) when is_binary(base_oid) do
    with {:ok, commit_output} <- run(["api", "repos/#{repository}/git/commits/#{base_oid}"]),
         {:ok, commit_payload} <- Jason.decode(commit_output),
         {:ok, tree_oid} <- base_tree_oid(commit_payload),
         {:ok, output} <- run(["api", "repos/#{repository}/git/trees/#{tree_oid}?recursive=1"]),
         {:ok, %{"tree" => tree, "truncated" => false}} when is_list(tree) <- Jason.decode(output) do
      {:ok, tree |> Enum.map(& &1["path"]) |> Enum.filter(&is_binary/1) |> MapSet.new()}
    else
      {:ok, payload} -> {:error, {:invalid_or_truncated_base_tree, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_base_tree_paths(_repository, base_oid), do: {:error, {:missing_base_oid, base_oid}}

  defp base_tree_oid(%{"tree" => %{"sha" => tree_oid}}) when is_binary(tree_oid) and tree_oid != "",
    do: {:ok, tree_oid}

  defp base_tree_oid(payload), do: {:error, {:missing_base_tree_oid, payload}}

  defp missing_paths_verified?(base_paths, claimed_missing_paths) do
    Enum.all?(claimed_missing_paths, &(not MapSet.member?(base_paths, &1)))
  end

  defp base_missing_paths(threads, head_sha) do
    threads
    |> current_head_comments(head_sha)
    |> Enum.flat_map(fn comment ->
      body = comment["body"] || ""

      if base_missing_claim_body?(body) do
        Regex.scan(~r/`([^`\r\n]+)`/, body, capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(&path_like?/1)
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp base_missing_claim?(threads, head_sha) do
    threads
    |> current_head_comments(head_sha)
    |> Enum.any?(fn comment -> base_missing_claim_body?(comment["body"] || "") end)
  end

  defp current_head_comments(threads, head_sha) do
    threads
    |> Enum.flat_map(fn thread -> get_in(thread, ["comments", "nodes"]) || [] end)
    |> Enum.filter(&(get_in(&1, ["commit", "oid"]) == head_sha))
  end

  defp base_missing_claim_body?(body) do
    Regex.match?(~r/base (?:branch|ref).*\b(?:missing|absent|does not (?:have|contain|exist))/i, body)
  end

  defp path_like?(value) do
    String.contains?(value, "/") and !String.contains?(value, " ")
  end

  defp normalize_snapshot(pull_request, checks, base_verification, clean_reviewed_head) do
    head_sha = pull_request["headRefOid"]
    threads = current_head_threads(pull_request)
    reviews = get_in(pull_request, ["reviews", "nodes"]) || []
    accepted_review = Enum.find(Enum.reverse(reviews), &accepted_review?(&1, head_sha))

    %{
      current_head_sha: head_sha,
      reviewed_head_sha: get_in(accepted_review || %{}, ["commit", "oid"]) || clean_reviewed_head,
      review_result: if(accepted_review || clean_reviewed_head, do: :no_major_issues, else: :missing),
      base_ref_oid: pull_request["baseRefOid"],
      base_verification_required: base_verification.required,
      base_verification: base_verification.result,
      required_checks: checks,
      threads: normalize_threads(threads, head_sha),
      structural_risk: structural_risk?(threads, head_sha)
    }
  end

  defp accepted_review?(review, head_sha) do
    get_in(review, ["commit", "oid"]) == head_sha and
      review["state"] in ["APPROVED", "COMMENTED"] and
      trusted_reviewer?(review["author"]) and
      String.contains?(review["body"] || "", "No major issues found")
  end

  defp trusted_reviewer?(author) when is_map(author) do
    Enum.any?(@trusted_reviewers, fn reviewer ->
      author["login"] == reviewer.login and
        author["__typename"] == reviewer.type and
        author["databaseId"] == reviewer.database_id
    end)
  end

  defp trusted_reviewer?(_author), do: false

  defp trusted_rest_reviewer?(user) when is_map(user) do
    user["login"] == "chatgpt-codex-connector[bot]" and
      user["type"] == "Bot" and
      user["id"] == 199_175_422
  end

  defp trusted_rest_reviewer?(_user), do: false

  defp normalize_threads(threads, head_sha) do
    Enum.flat_map(threads, fn thread ->
      (get_in(thread, ["comments", "nodes"]) || [])
      |> Enum.filter(&(get_in(&1, ["commit", "oid"]) == head_sha))
      |> Enum.map(fn comment ->
        body = comment["body"] || ""

        %{
          resolved: thread["isResolved"] == true,
          priority: priority(body),
          body: body,
          path: comment["path"],
          url: comment["url"],
          commit_sha: get_in(comment, ["commit", "oid"])
        }
      end)
    end)
  end

  defp current_head_threads(pull_request) do
    head_sha = pull_request["headRefOid"]

    (get_in(pull_request, ["reviewThreads", "nodes"]) || [])
    |> Enum.filter(fn thread ->
      (get_in(thread, ["comments", "nodes"]) || [])
      |> Enum.any?(&(get_in(&1, ["commit", "oid"]) == head_sha))
    end)
  end

  defp priority(body) do
    case Regex.run(~r/\bP([1-4])\b/i, body, capture: :all_but_first) do
      [priority] -> String.to_integer(priority)
      _ -> nil
    end
  end

  defp structural_risk?(threads, head_sha) do
    threads
    |> Enum.reject(&(&1["isResolved"] == true))
    |> current_head_comments(head_sha)
    |> Enum.any?(fn comment ->
      Regex.match?(~r/one[- ]off patch|scope (?:keeps )?(?:expanding|growth)|spec(?:ification)? conflict/i, comment["body"] || "")
    end)
  end

  defp normalize_check_state(value) when is_binary(value) do
    case String.downcase(value) do
      state when state in ["pass", "success"] -> :success
      state when state in ["skipped", "skipping"] -> :skipped
      "neutral" -> :neutral
      "pending" -> :pending
      _ -> :failure
    end
  end

  defp normalize_check_state(_value), do: :failure

  defp run(args) do
    case run_with_status(args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:command_error, Exception.message(error)}}
  end

  defp run_with_status(args), do: System.cmd("gh", args, stderr_to_stdout: true)
end
