defmodule SymphonyElixir.LinearClientResilienceTest do
  use SymphonyElixir.TestSupport

  test "linear client retries transient 429 responses and respects Retry-After" do
    test_pid = self()

    request_fun = fn _payload, _headers ->
      attempt = Process.get(:linear_retry_after_attempt, 0) + 1
      Process.put(:linear_retry_after_attempt, attempt)
      send(test_pid, {:request_attempt, attempt})

      case attempt do
        1 ->
          {:ok,
           %{
             status: 429,
             body: %{"errors" => [%{"message" => "rate limited"}]},
             headers: %{"retry-after" => ["2"]}
           }}

        _ ->
          {:ok,
           %{
             status: 200,
             body: %{"data" => %{"viewer" => %{"id" => "usr_1"}}},
             headers: %{}
           }}
      end
    end

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "usr_1"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               request_fun: request_fun,
               retry_attempts: 2,
               retry_base_delay_ms: 100,
               retry_max_delay_ms: 1_000,
               sleep_fun: fn ms -> send(test_pid, {:sleep_ms, ms}) end,
               circuit_key: make_ref()
             )

    assert_received {:request_attempt, 1}
    assert_received {:sleep_ms, 2_000}
    assert_received {:request_attempt, 2}
  end

  test "linear client retries transient timeout failures with exponential backoff" do
    test_pid = self()

    request_fun = fn _payload, _headers ->
      attempt = Process.get(:linear_timeout_attempt, 0) + 1
      Process.put(:linear_timeout_attempt, attempt)
      send(test_pid, {:request_attempt, attempt})

      case attempt do
        1 -> {:error, :timeout}
        2 -> {:error, :timeout}
        _ -> {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "usr_2"}}}, headers: %{}}}
      end
    end

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "usr_2"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               request_fun: request_fun,
               retry_attempts: 3,
               retry_base_delay_ms: 50,
               retry_max_delay_ms: 1_000,
               sleep_fun: fn ms -> send(test_pid, {:sleep_ms, ms}) end,
               circuit_key: make_ref()
             )

    assert_received {:request_attempt, 1}
    assert_received {:sleep_ms, 50}
    assert_received {:request_attempt, 2}
    assert_received {:sleep_ms, 100}
    assert_received {:request_attempt, 3}
  end

  test "linear client opens circuit breaker after threshold and recovers after cooldown" do
    test_pid = self()
    circuit_key = make_ref()
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    time_fun = fn -> Agent.get(clock, & &1) end

    failing_request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      send(test_pid, :request_called)
      {:error, :timeout}
    end

    opts = [
      request_fun: failing_request_fun,
      retry_attempts: 0,
      retry_base_delay_ms: 10,
      retry_max_delay_ms: 10,
      circuit_failure_threshold: 2,
      circuit_cooldown_ms: 1_000,
      monotonic_time_fun: time_fun,
      sleep_fun: fn _ms -> :ok end,
      circuit_key: circuit_key
    ]

    assert {:error, {:linear_api_request, :timeout, first_metadata}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, opts)

    assert get_in(first_metadata, [:circuit, :consecutive_failures]) == 1
    assert get_in(first_metadata, [:circuit, :state]) == :closed

    assert {:error, {:linear_api_request, :timeout, second_metadata}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, opts)

    assert get_in(second_metadata, [:circuit, :consecutive_failures]) == 2
    assert get_in(second_metadata, [:circuit, :state]) == :open

    assert {:error, {:linear_api_request, {:circuit_open, open_metadata}, third_metadata}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, opts)

    assert open_metadata[:state] == :open
    assert open_metadata[:open_remaining_ms] == 1_000
    assert get_in(third_metadata, [:circuit, :state]) == :open

    assert Agent.get(counter, & &1) == 2

    Agent.update(clock, fn _ -> 1_500 end)

    succeeding_request_fun = fn _payload, _headers ->
      Agent.update(counter, &(&1 + 1))
      send(test_pid, :request_called)
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "usr_3"}}}, headers: %{}}}
    end

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "usr_3"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               Keyword.put(opts, :request_fun, succeeding_request_fun)
             )

    assert Agent.get(counter, & &1) == 3
  end

  test "linear client proactively backs off when rate-limit budget is low" do
    test_pid = self()

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "usr_4"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               request_fun: fn _payload, _headers ->
                 {:ok,
                  %{
                    status: 200,
                    body: %{"data" => %{"viewer" => %{"id" => "usr_4"}}},
                    headers: %{
                      "x-ratelimit-requests-remaining" => ["1"],
                      "x-ratelimit-requests-reset" => ["3"]
                    }
                  }}
               end,
               rate_limit_low_remaining: 2,
               sleep_fun: fn ms -> send(test_pid, {:sleep_ms, ms}) end,
               circuit_key: make_ref()
             )

    assert_received {:sleep_ms, 1_000}
  end

  test "linear client happy path performs no retry sleep" do
    test_pid = self()

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "usr_5"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               request_fun: fn _payload, _headers ->
                 send(test_pid, :request_called)
                 {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "usr_5"}}}, headers: %{}}}
               end,
               sleep_fun: fn ms -> send(test_pid, {:sleep_ms, ms}) end,
               circuit_key: make_ref()
             )

    assert_received :request_called
    refute_received {:sleep_ms, _}
  end
end
