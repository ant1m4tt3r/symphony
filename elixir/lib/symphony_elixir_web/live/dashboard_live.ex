defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
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

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Active work</h2>
              <p class="section-copy">Task cards for issues currently being worked on.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active tasks.</p>
          <% else %>
            <div class="task-card-grid">
              <article :for={entry <- @payload.running} class="task-card">
                <div class="task-card-header">
                  <div class="task-card-id-row">
                    <span class="task-card-id"><%= entry.issue_identifier %></span>
                    <span class={state_badge_class(entry.state)}>
                      <%= entry.state %>
                    </span>
                  </div>
                  <span class={"task-card-priority #{priority_class(entry.priority)}"}>
                    <%= priority_label(entry[:priority]) %>
                  </span>
                </div>

                <h3 class="task-card-title"><%= entry[:title] || entry.issue_identifier %></h3>

                <div class="task-card-meta">
                  <span class="task-card-meta-item">
                    <span class="task-card-meta-label">Assignee</span>
                    <span class="task-card-meta-value mono"><%= assignee_label(entry[:assignee_id]) %></span>
                  </span>
                  <span class="task-card-meta-item">
                    <span class="task-card-meta-label">Updated</span>
                    <span class="task-card-meta-value mono"><%= format_relative_time(entry[:updated_at] || entry[:started_at], @now) %></span>
                  </span>
                  <span class="task-card-meta-item">
                    <span class="task-card-meta-label">Runtime</span>
                    <span class="task-card-meta-value numeric"><%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %></span>
                  </span>
                </div>

                <div class="task-card-links">
                  <%= if entry[:url] do %>
                    <a class="task-card-link" href={entry.url} target="_blank" rel="noopener">
                      Linear
                    </a>
                  <% end %>
                  <%= if entry[:branch_name] do %>
                    <a class="task-card-link task-card-link-secondary" href={"https://github.com/search?q=#{entry.branch_name}&type=pullrequests"} target="_blank" rel="noopener">
                      PR
                    </a>
                  <% end %>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col style="width: 12rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Agent runtime</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
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
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="agent-stack">
                        <span class={agent_badge_class(agent_field(entry.agent, :engine))}>
                          <%= display_agent_engine(agent_field(entry.agent, :engine)) %>
                        </span>
                        <span class="muted event-meta">
                          model · <span class="mono"><%= display_or_na(agent_field(entry.agent, :model)) %></span>
                        </span>
                        <span class="muted event-meta">
                          provider · <span class="mono"><%= display_or_na(agent_field(entry.agent, :provider)) %></span>
                        </span>
                      </div>
                    </td>
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

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
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
                  <tr :for={entry <- @payload.retrying}>
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

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
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

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
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

  defp priority_label(nil), do: "No priority"
  defp priority_label(0), do: "No priority"
  defp priority_label(1), do: "Urgent"
  defp priority_label(2), do: "High"
  defp priority_label(3), do: "Medium"
  defp priority_label(4), do: "Low"
  defp priority_label(_), do: "Unknown"

  defp priority_class(1), do: "priority-urgent"
  defp priority_class(2), do: "priority-high"
  defp priority_class(3), do: "priority-medium"
  defp priority_class(4), do: "priority-low"
  defp priority_class(_), do: ""

  defp truncate_id(id) when is_binary(id) do
    if String.length(id) > 12 do
      String.slice(id, 0, 8) <> "..."
    else
      id
    end
  end

  defp truncate_id(id), do: to_string(id)

  defp assignee_label(nil), do: "Unassigned"
  defp assignee_label(id), do: truncate_id(id)

  defp format_relative_time(nil, _now), do: "n/a"

  defp format_relative_time(time, now) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, parsed, _offset} -> format_relative_time(parsed, now)
      _ -> "n/a"
    end
  end

  defp format_relative_time(%DateTime{} = time, %DateTime{} = now) do
    diff = DateTime.diff(now, time, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp display_or_na(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: "n/a", else: trimmed
  end

  defp display_or_na(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> display_or_na()
  end

  defp display_or_na(_value), do: "n/a"

  defp agent_field(agent, field) when is_map(agent) do
    Map.get(agent, field) || Map.get(agent, Atom.to_string(field))
  end

  defp agent_field(_agent, _field), do: nil

  defp display_agent_engine(engine) do
    case display_or_na(engine) do
      "codex" -> "Codex"
      "claude" -> "Claude"
      "opencode" -> "OpenCode"
      "mixed" -> "Mixed"
      "custom" -> "Custom"
      other -> other
    end
  end

  defp agent_badge_class(engine) do
    base = "agent-badge"

    case display_or_na(engine) do
      "codex" -> "#{base} agent-badge-codex"
      "claude" -> "#{base} agent-badge-claude"
      "opencode" -> "#{base} agent-badge-opencode"
      "mixed" -> "#{base} agent-badge-mixed"
      "custom" -> "#{base} agent-badge-custom"
      _ -> "#{base} agent-badge-unknown"
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
