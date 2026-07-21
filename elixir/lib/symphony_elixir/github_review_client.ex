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
              pageInfo { hasNextPage endCursor }
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
         {:ok, checks} <- required_checks(repository, pull_request["headRefOid"]),
         {:ok, base_verification} <- verify_base_claims(repository, pull_request) do
      {:ok,
       pull_request
       |> normalize_snapshot(checks, base_verification)
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

  defp required_checks(repository, head_sha) do
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
         {:ok, payload} <- merge_check_run_pages(pages) do
      normalize_expected_checks(payload)
    else
      {:error, reason} -> {:error, reason}
    end
  end

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
    page_info = get_in(thread, ["comments", "pageInfo"]) || %{}

    if page_info["hasNextPage"] == true do
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
    results = Enum.map(paths, &base_path_exists?(repository, base_oid, &1))

    if Enum.all?(results, &(&1 == true)) do
      {:ok, %{required: true, result: :verified}}
    else
      {:ok, %{required: true, result: :unverified}}
    end
  end

  defp base_path_exists?(repository, base_oid, path) when is_binary(base_oid) do
    endpoint = "repos/#{repository}/contents/#{path}?ref=#{base_oid}"
    match?({:ok, _}, run(["api", endpoint, "--silent"]))
  end

  defp base_path_exists?(_repository, _base_oid, _path), do: false

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

  defp normalize_snapshot(pull_request, checks, base_verification) do
    head_sha = pull_request["headRefOid"]
    threads = current_head_threads(pull_request)
    reviews = get_in(pull_request, ["reviews", "nodes"]) || []
    accepted_review = Enum.find(Enum.reverse(reviews), &accepted_review?(&1, head_sha))

    %{
      current_head_sha: head_sha,
      reviewed_head_sha: get_in(accepted_review || %{}, ["commit", "oid"]),
      review_result: if(accepted_review, do: :no_major_issues, else: :missing),
      base_ref_oid: pull_request["baseRefOid"],
      base_verification_required: base_verification.required,
      base_verification: base_verification.result,
      required_checks: checks,
      threads: normalize_threads(threads, head_sha),
      structural_risk: structural_risk?(threads)
    }
  end

  defp accepted_review?(review, head_sha) do
    get_in(review, ["commit", "oid"]) == head_sha and
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

  defp structural_risk?(threads) do
    threads
    |> Enum.flat_map(fn thread -> get_in(thread, ["comments", "nodes"]) || [] end)
    |> Enum.any?(fn comment ->
      Regex.match?(~r/one[- ]off patch|scope (?:keeps )?(?:expanding|growth)|spec(?:ification)? conflict/i, comment["body"] || "")
    end)
  end

  defp normalize_check_state(value) when is_binary(value) do
    case String.downcase(value) do
      state when state in ["pass", "success"] -> :success
      "skipped" -> :skipped
      "neutral" -> :neutral
      "pending" -> :pending
      _ -> :failure
    end
  end

  defp normalize_check_state(_value), do: :failure

  defp run(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:command_error, Exception.message(error)}}
  end
end
