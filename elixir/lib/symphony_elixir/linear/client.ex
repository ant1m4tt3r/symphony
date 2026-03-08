defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @default_retry_attempts 3
  @default_retry_base_delay_ms 250
  @default_retry_max_delay_ms 5_000
  @default_circuit_failure_threshold 5
  @default_circuit_cooldown_ms 30_000
  @default_rate_limit_low_remaining 5
  @default_rate_limit_backoff_ms 1_000
  @default_rate_limit_backoff_cap_ms 30_000
  @circuit_table :symphony_linear_client_circuit_breaker
  @transient_request_reasons MapSet.new([
                               :timeout,
                               :connect_timeout,
                               :closed,
                               :econnrefused,
                               :econnreset,
                               :enetdown,
                               :enetunreach,
                               :ehostdown,
                               :ehostunreach,
                               :nxdomain
                             ])

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    project_slug = Config.linear_project_slug()

    cond do
      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, Config.linear_active_states(), assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      project_slug = Config.linear_project_slug()

      cond do
        is_nil(Config.linear_api_token()) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)
    resilience = resilience_options(opts)

    case graphql_headers() do
      {:ok, headers} ->
        with :ok <- ensure_circuit_ready(resilience),
             {:ok, response, _retry_metadata} <-
               perform_graphql_with_retries(payload, headers, request_fun, resilience),
             :ok <- maybe_apply_proactive_rate_limit_backoff(response, resilience),
             :ok <- clear_circuit_failures(resilience) do
          {:ok, Map.get(response, :body)}
        else
          {:error, {:linear_api_status, status, metadata}} ->
            log_status_failure(payload, status, metadata)
            {:error, {:linear_api_status, status, metadata}}

          {:error, {:linear_api_status_response, status, response}} ->
            Logger.error(
              "Linear GraphQL request failed status=#{status}" <>
                linear_error_context(payload, response)
            )

            {:error, {:linear_api_status, status}}

          {:error, {:linear_api_request, reason, metadata}} = error ->
            log_request_failure(reason, metadata)
            error

          {:error, {:linear_api_request, reason}} = error ->
            Logger.error("Linear GraphQL request failed: #{inspect(reason)}" <> resilience_log_context(%{}))
            error

          {:error, {:linear_api_status, status}} = error ->
            Logger.error("Linear GraphQL request failed status=#{status}" <> resilience_log_context(%{}))
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec reset_resilience_state_for_test(term()) :: :ok
  def reset_resilience_state_for_test(circuit_key \\ :default) do
    ensure_circuit_table()
    :ets.delete(@circuit_table, circuit_key)
    :ok
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    case graphql(@query_by_ids, %{
           ids: ids,
           first: Enum.min([length(ids), @issue_page_size]),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        decode_linear_response(body, assignee_filter)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.linear_api_token() do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.linear_endpoint(),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp resilience_options(opts) do
    %{
      circuit_key: Keyword.get(opts, :circuit_key, :default),
      retry_attempts: non_negative_integer_option(opts, :retry_attempts, @default_retry_attempts),
      retry_base_delay_ms: positive_integer_option(opts, :retry_base_delay_ms, @default_retry_base_delay_ms),
      retry_max_delay_ms: positive_integer_option(opts, :retry_max_delay_ms, @default_retry_max_delay_ms),
      circuit_failure_threshold: positive_integer_option(opts, :circuit_failure_threshold, @default_circuit_failure_threshold),
      circuit_cooldown_ms: positive_integer_option(opts, :circuit_cooldown_ms, @default_circuit_cooldown_ms),
      rate_limit_low_remaining: positive_integer_option(opts, :rate_limit_low_remaining, @default_rate_limit_low_remaining),
      rate_limit_backoff_ms: positive_integer_option(opts, :rate_limit_backoff_ms, @default_rate_limit_backoff_ms),
      rate_limit_backoff_cap_ms: positive_integer_option(opts, :rate_limit_backoff_cap_ms, @default_rate_limit_backoff_cap_ms),
      sleep_fun: Keyword.get(opts, :sleep_fun, &Process.sleep/1),
      monotonic_time_fun: Keyword.get(opts, :monotonic_time_fun, fn -> System.monotonic_time(:millisecond) end),
      wall_clock_fun: Keyword.get(opts, :wall_clock_fun, &DateTime.utc_now/0)
    }
  end

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp non_negative_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp ensure_circuit_ready(resilience) when is_map(resilience) do
    state = read_circuit_state(resilience)
    now_ms = resilience.monotonic_time_fun.()
    open_until_ms = Map.get(state, :open_until_ms)

    cond do
      is_integer(open_until_ms) and open_until_ms > now_ms ->
        circuit_metadata =
          circuit_metadata(
            state,
            resilience,
            now_ms,
            if(open_until_ms > now_ms, do: :open, else: :closed)
          )

        metadata = %{
          retry: %{attempt: 0, max_attempts: resilience.retry_attempts + 1, retries: 0, exhausted: false},
          circuit: circuit_metadata
        }

        Logger.warning("Linear GraphQL circuit breaker open; skipping request" <> resilience_log_context(metadata))

        {:error, {:linear_api_request, {:circuit_open, circuit_metadata}, metadata}}

      is_integer(open_until_ms) and open_until_ms <= now_ms ->
        write_circuit_state(resilience, default_circuit_state())
        :ok

      true ->
        :ok
    end
  end

  defp perform_graphql_with_retries(payload, headers, request_fun, resilience) do
    max_attempts = resilience.retry_attempts + 1
    do_perform_graphql_with_retries(payload, headers, request_fun, resilience, 1, max_attempts, nil)
  end

  defp do_perform_graphql_with_retries(payload, headers, request_fun, resilience, attempt, max_attempts, last_delay_ms) do
    case request_fun.(payload, headers) do
      {:ok, raw_response} ->
        response = normalize_response(raw_response)
        status = Map.get(response, :status)
        retry_after_ms = extract_retry_after_ms(response, resilience)

        cond do
          status == 200 ->
            retry_metadata = %{
              attempt: attempt,
              max_attempts: max_attempts,
              retries: attempt - 1,
              exhausted: false,
              last_delay_ms: last_delay_ms,
              retry_after_ms: retry_after_ms
            }

            {:ok, response, retry_metadata}

          transient_status?(status) and attempt < max_attempts ->
            delay_ms = retry_delay_ms(attempt, retry_after_ms, resilience)

            Logger.warning(
              "Linear GraphQL transient status; scheduling retry" <>
                resilience_log_context(%{
                  retry: %{
                    attempt: attempt,
                    max_attempts: max_attempts,
                    retries: attempt,
                    exhausted: false,
                    last_delay_ms: delay_ms,
                    retry_after_ms: retry_after_ms
                  },
                  status: status
                })
            )

            resilience.sleep_fun.(delay_ms)

            do_perform_graphql_with_retries(
              payload,
              headers,
              request_fun,
              resilience,
              attempt + 1,
              max_attempts,
              delay_ms
            )

          transient_status?(status) ->
            circuit = record_circuit_failure(resilience)

            metadata = %{
              retry: %{
                attempt: attempt,
                max_attempts: max_attempts,
                retries: max(attempt - 1, 0),
                exhausted: true,
                last_delay_ms: last_delay_ms,
                retry_after_ms: retry_after_ms
              },
              circuit: circuit,
              rate_limits: extract_rate_limit_headers(response, resilience),
              response_body: Map.get(response, :body)
            }

            {:error, {:linear_api_status, status, metadata}}

          is_integer(status) ->
            :ok = clear_circuit_failures(resilience)
            {:error, {:linear_api_status_response, status, response}}

          true ->
            {:error, {:linear_api_request, {:invalid_linear_response, response}}}
        end

      {:error, reason} ->
        if transient_request_error?(reason) and attempt < max_attempts do
          delay_ms = retry_delay_ms(attempt, nil, resilience)

          Logger.warning(
            "Linear GraphQL transport failure; scheduling retry" <>
              resilience_log_context(%{
                retry: %{
                  attempt: attempt,
                  max_attempts: max_attempts,
                  retries: attempt,
                  exhausted: false,
                  last_delay_ms: delay_ms
                },
                request_reason: inspect(reason)
              })
          )

          resilience.sleep_fun.(delay_ms)

          do_perform_graphql_with_retries(
            payload,
            headers,
            request_fun,
            resilience,
            attempt + 1,
            max_attempts,
            delay_ms
          )
        else
          if transient_request_error?(reason) do
            circuit = record_circuit_failure(resilience)

            metadata = %{
              retry: %{
                attempt: attempt,
                max_attempts: max_attempts,
                retries: max(attempt - 1, 0),
                exhausted: true,
                last_delay_ms: last_delay_ms
              },
              circuit: circuit
            }

            {:error, {:linear_api_request, reason, metadata}}
          else
            {:error, {:linear_api_request, reason}}
          end
        end
    end
  end

  defp log_status_failure(payload, status, metadata) do
    response = %{status: status, body: Map.get(metadata, :response_body)}

    Logger.error(
      "Linear GraphQL request failed status=#{status}" <>
        linear_error_context(payload, response) <>
        resilience_log_context(metadata)
    )
  end

  defp log_request_failure(reason, metadata) do
    Logger.error("Linear GraphQL request failed: #{inspect(reason)}" <> resilience_log_context(metadata))
  end

  defp retry_delay_ms(attempt, retry_after_ms, resilience) do
    exponential_delay_ms =
      resilience.retry_base_delay_ms
      |> Kernel.*(Integer.pow(2, max(attempt - 1, 0)))
      |> min(resilience.retry_max_delay_ms)

    case retry_after_ms do
      value when is_integer(value) and value >= 0 -> max(value, exponential_delay_ms)
      _ -> exponential_delay_ms
    end
  end

  defp maybe_apply_proactive_rate_limit_backoff(response, resilience) do
    rate_limits = extract_rate_limit_headers(response, resilience)
    delay_ms = proactive_rate_limit_delay_ms(rate_limits, resilience)

    if delay_ms > 0 do
      metadata = %{rate_limits: Map.put(rate_limits, :proactive_delay_ms, delay_ms)}

      Logger.warning("Linear GraphQL proactive rate-limit backoff engaged" <> resilience_log_context(metadata))

      resilience.sleep_fun.(delay_ms)
    end

    :ok
  end

  defp proactive_rate_limit_delay_ms(rate_limits, resilience) when is_map(rate_limits) do
    if low_rate_limit_budget?(rate_limits, resilience.rate_limit_low_remaining) do
      delay_ms =
        [Map.get(rate_limits, :requests_reset_ms), Map.get(rate_limits, :complexity_reset_ms)]
        |> Enum.filter(&(is_integer(&1) and &1 > 0))
        |> case do
          [] -> resilience.rate_limit_backoff_ms
          values -> min(Enum.max(values), resilience.rate_limit_backoff_ms)
        end

      min(delay_ms, resilience.rate_limit_backoff_cap_ms)
    else
      0
    end
  end

  defp proactive_rate_limit_delay_ms(_rate_limits, _resilience), do: 0

  defp low_rate_limit_budget?(rate_limits, threshold) do
    requests_remaining = Map.get(rate_limits, :requests_remaining)
    complexity_remaining = Map.get(rate_limits, :complexity_remaining)

    (is_integer(requests_remaining) and requests_remaining <= threshold) or
      (is_integer(complexity_remaining) and complexity_remaining <= threshold)
  end

  defp extract_rate_limit_headers(response, resilience) do
    headers = Map.get(response, :headers, %{})

    %{
      requests_remaining: parse_integer_header(headers, "x-ratelimit-requests-remaining"),
      complexity_remaining: parse_integer_header(headers, "x-ratelimit-complexity-remaining"),
      requests_reset_ms: parse_reset_header_ms(headers, "x-ratelimit-requests-reset", resilience),
      complexity_reset_ms: parse_reset_header_ms(headers, "x-ratelimit-complexity-reset", resilience)
    }
    |> compact_map()
  end

  defp extract_retry_after_ms(response, resilience) do
    headers = Map.get(response, :headers, %{})
    parse_retry_after_ms(first_header_value(headers, "retry-after"), resilience)
  end

  defp parse_integer_header(headers, header_name) do
    headers
    |> first_header_value(header_name)
    |> parse_integer_value()
  end

  defp parse_reset_header_ms(headers, header_name, resilience) do
    case first_header_value(headers, header_name) |> parse_integer_value() do
      nil ->
        nil

      value when value <= 0 ->
        0

      value when value >= 1_000_000_000 ->
        now_ms =
          resilience.wall_clock_fun.()
          |> DateTime.to_unix(:millisecond)

        max(value * 1_000 - now_ms, 0)

      value ->
        value * 1_000
    end
  end

  defp parse_retry_after_ms(nil, _resilience), do: nil

  defp parse_retry_after_ms(value, resilience) when is_binary(value) do
    trimmed = String.trim(value)

    case parse_integer_value(trimmed) do
      seconds when is_integer(seconds) and seconds >= 0 ->
        seconds * 1_000

      _ ->
        parse_retry_after_http_date_ms(trimmed, resilience)
    end
  end

  defp parse_retry_after_ms(_value, _resilience), do: nil

  defp parse_retry_after_http_date_ms(value, resilience) when is_binary(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        with {:ok, date} <- Date.new(year, month, day),
             {:ok, time} <- Time.new(hour, minute, second),
             {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
          now_ms =
            resilience.wall_clock_fun.()
            |> DateTime.to_unix(:millisecond)

          max(DateTime.to_unix(datetime, :millisecond) - now_ms, 0)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer_value(_value), do: nil

  defp normalize_response(%{} = response) do
    %{
      status: parse_status(Map.get(response, :status) || Map.get(response, "status")),
      body: Map.get(response, :body) || Map.get(response, "body"),
      headers: normalize_headers(Map.get(response, :headers) || Map.get(response, "headers") || %{})
    }
  end

  defp parse_status(status) when is_integer(status), do: status
  defp parse_status(_status), do: nil

  defp normalize_headers(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      put_header_values(acc, key, value)
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn
      {key, value}, acc -> put_header_values(acc, key, value)
      _, acc -> acc
    end)
  end

  defp normalize_headers(_headers), do: %{}

  defp put_header_values(acc, key, values) do
    normalized_key =
      key
      |> to_string()
      |> String.downcase()

    normalized_values =
      case values do
        value when is_binary(value) -> [value]
        value when is_list(value) -> Enum.map(value, &to_string/1)
        value -> [to_string(value)]
      end

    Map.put(acc, normalized_key, normalized_values)
  end

  defp first_header_value(headers, key) when is_map(headers) and is_binary(key) do
    normalized_key = String.downcase(key)

    case Map.get(headers, normalized_key) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp first_header_value(_headers, _key), do: nil

  defp transient_status?(status) when is_integer(status) do
    status == 429 or (status >= 500 and status <= 599)
  end

  defp transient_status?(_status), do: false

  defp transient_request_error?(%{reason: reason}), do: transient_request_error?(reason)
  defp transient_request_error?({reason, _}) when is_atom(reason), do: MapSet.member?(@transient_request_reasons, reason)
  defp transient_request_error?({:tls_alert, _}), do: true
  defp transient_request_error?(reason) when is_atom(reason), do: MapSet.member?(@transient_request_reasons, reason)
  defp transient_request_error?(_reason), do: false

  defp clear_circuit_failures(resilience) do
    state = read_circuit_state(resilience)

    if Map.get(state, :consecutive_failures, 0) > 0 or is_integer(Map.get(state, :open_until_ms)) do
      write_circuit_state(resilience, default_circuit_state())
    end

    :ok
  end

  defp record_circuit_failure(resilience) do
    state = read_circuit_state(resilience)
    now_ms = resilience.monotonic_time_fun.()
    failures = Map.get(state, :consecutive_failures, 0) + 1
    threshold = resilience.circuit_failure_threshold
    should_open? = failures >= threshold
    open_until_ms = if should_open?, do: now_ms + resilience.circuit_cooldown_ms, else: nil

    next_state = %{consecutive_failures: failures, open_until_ms: open_until_ms}
    write_circuit_state(resilience, next_state)

    metadata = circuit_metadata(next_state, resilience, now_ms, if(should_open?, do: :open, else: :closed))

    if should_open? do
      Logger.error("Linear GraphQL circuit breaker tripped" <> resilience_log_context(%{circuit: metadata}))
    end

    metadata
  end

  defp circuit_metadata(state, resilience, now_ms, state_name) do
    open_until_ms = Map.get(state, :open_until_ms)

    %{
      state: state_name,
      consecutive_failures: Map.get(state, :consecutive_failures, 0),
      failure_threshold: resilience.circuit_failure_threshold,
      cooldown_ms: resilience.circuit_cooldown_ms,
      open_until_ms: open_until_ms,
      open_remaining_ms: if(is_integer(open_until_ms), do: max(open_until_ms - now_ms, 0), else: 0)
    }
    |> compact_map()
  end

  defp read_circuit_state(resilience) do
    ensure_circuit_table()

    case :ets.lookup(@circuit_table, resilience.circuit_key) do
      [{_key, state}] when is_map(state) ->
        Map.merge(default_circuit_state(), state)

      _ ->
        default_circuit_state()
    end
  end

  defp write_circuit_state(resilience, state) do
    ensure_circuit_table()
    true = :ets.insert(@circuit_table, {resilience.circuit_key, state})
    :ok
  end

  defp ensure_circuit_table do
    case :ets.whereis(@circuit_table) do
      :undefined ->
        try do
          :ets.new(@circuit_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
        rescue
          ArgumentError -> @circuit_table
        end

      _table ->
        @circuit_table
    end

    :ok
  end

  defp default_circuit_state do
    %{consecutive_failures: 0, open_until_ms: nil}
  end

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp resilience_log_context(metadata) when map_size(metadata) == 0, do: ""

  defp resilience_log_context(metadata) when is_map(metadata) do
    " metadata=" <> inspect(metadata, limit: 20, printable_limit: @max_error_body_log_bytes)
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.linear_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
