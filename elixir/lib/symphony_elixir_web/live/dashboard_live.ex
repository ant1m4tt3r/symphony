defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign_filters_from_params(params)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true

  def handle_params(params, _uri, socket) do
    socket = assign_filters_from_params(socket, params)
    {:noreply, socket}
  end

  defp assign_filters_from_params(socket, params) do
    state_filter = Map.get(params, "state", "")
    priority_sort = Map.get(params, "sort", "")
    assignee_filter = Map.get(params, "assignee", "")

    socket
    |> assign(:state_filter, state_filter)
    |> assign(:priority_sort, priority_sort)
    |> assign(:assignee_filter, assignee_filter)
  end

  @impl true

  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true

  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    filtered_running =
      filter_and_sort_running(
        assigns.payload.running,
        assigns.state_filter,
        assigns.priority_sort,
        assigns.assignee_filter
      )

    filtered_retrying =
      filter_and_sort_retrying(
        assigns.payload.retrying,
        assigns.state_filter,
        assigns.priority_sort,
        assigns.assignee_filter
      )

    assigns =
      assigns
      |> assign(:filtered_running, filtered_running)
      |> assign(:filtered_retrying, filtered_retrying)

    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if assigns.payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= assigns.payload.error.code %>:</strong> <%= assigns.payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= assigns.payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= assigns.payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(assigns.payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(assigns.payload.codex_totals.input_tokens) %> / Out <%= format_int(assigns.payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(assigns.payload, assigns.now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(assigns.payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
            <div class="filter-controls">
              <select name="state" class="filter-select" phx-change="filter_changed">
                <option value="">All States</option>
                <option value="In Progress" selected={assigns.state_filter == "In Progress"}>In Progress</option>
                <option value="Todo" selected={assigns.state_filter == "Todo"}>Todo</option>
                <option value="In Review" selected={assigns.state_filter == "In Review"}>In Review</option>
              </select>
              <select name="sort" class="filter-select" phx-change="filter_changed">
                <option value="">Default Sort</option>
                <option value="priority" selected={assigns.priority_sort == "priority"}>Priority</option>
                <option value="priority_desc" selected={assigns.priority_sort == "priority_desc"}>Priority (High First)</option>
              </select>
              <input
                type="text"
                name="assignee"
                class="filter-input"
                placeholder="Filter by assignee..."
                value={assigns.assignee_filter}
                phx-change="filter_changed"
              />
            </div>
          </div>

          <%= if assigns.filtered_running == [] do %>
            <p class="empty-state">No active sessions<%= if assigns.state_filter != "" or assigns.assignee_filter != "", do: " match the current filters" %>.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- assigns.filtered_running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, assigns.now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if assigns.filtered_retrying == [] do %>
            <p class="empty-state">No issues are currently backing off<%= if assigns.state_filter != "" or assigns.assignee_filter != "", do: " matching the current filters" %>.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- assigns.filtered_retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  @impl true

  def handle_event(
        "filter_changed",
        %{"state" => state, "sort" => sort, "assignee" => assignee},
        socket
      ) do
    params =
      Enum.reject(
        [
          {"state", state},
          {"sort", sort},
          {"assignee", assignee}
        ],
        fn {_k, v} -> v == "" end
      )
      |> Map.new()

    {:noreply, patch_filter_params(socket, params)}
  end

  def handle_event("filter_changed", params, socket) do
    state = Map.get(params, "state", "")
    sort = Map.get(params, "sort", "")
    assignee = Map.get(params, "assignee", "")

    params =
      Enum.reject(
        [
          {"state", state},
          {"sort", sort},
          {"assignee", assignee}
        ],
        fn {_k, v} -> v == "" end
      )
      |> Map.new()

    {:noreply, patch_filter_params(socket, params)}
  end

  defp patch_filter_params(socket, params) do
    socket
    |> assign(:state_filter, Map.get(params, "state", ""))
    |> assign(:priority_sort, Map.get(params, "sort", ""))
    |> assign(:assignee_filter, Map.get(params, "assignee", ""))
    |> push_patch(to: "?#{URI.encode_query(params)}")
  end

  defp filter_and_sort_running(entries, state_filter, priority_sort, assignee_filter) do
    entries
    |> Enum.filter(fn entry ->
      matches_state_filter(entry, state_filter) and
        matches_assignee_filter(entry, assignee_filter)
    end)
    |> Enum.sort_by(&sort_key(&1, priority_sort))
  end

  defp filter_and_sort_retrying(entries, state_filter, _priority_sort, assignee_filter) do
    entries
    |> Enum.filter(fn entry ->
      matches_state_filter(entry, state_filter) and
        matches_assignee_filter(entry, assignee_filter)
    end)
  end

  defp matches_state_filter(_entry, ""), do: true

  defp matches_state_filter(entry, state) do
    entry.state == state
  end

  defp matches_assignee_filter(_entry, ""), do: true

  defp matches_assignee_filter(entry, assignee) do
    entry.assignee_id == assignee
  end

  defp sort_key(entry, "priority") do
    {priority_sort_key(entry.priority), entry.issue_identifier || ""}
  end

  defp sort_key(entry, "priority_desc") do
    {-priority_sort_key(entry.priority), entry.issue_identifier || ""}
  end

  defp sort_key(entry, _), do: {0, entry.issue_identifier || ""}

  defp priority_sort_key(nil), do: 100
  defp priority_sort_key(p) when is_integer(p), do: p

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now)
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
