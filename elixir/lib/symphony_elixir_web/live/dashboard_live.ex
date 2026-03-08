defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @runtime_health_fresh_seconds 120
  @runtime_health_stale_seconds 600
  @update_preview_char_limit 140

  @toggleable_columns [
    %{id: "runtime_health", label: "Runtime health"},
    %{id: "runtime", label: "Runtime"},
    %{id: "agent", label: "Agent"},
    %{id: "tokens", label: "Tokens"},
    %{id: "update", label: "Latest update"}
  ]

  @default_visible MapSet.new(["runtime_health", "runtime", "agent", "tokens", "update"])

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:visible_columns, @default_visible)
      |> assign(:toggleable_columns, @toggleable_columns)
      |> assign(:column_menu_open, false)

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
  def handle_event("toggle-column", %{"column" => column_id}, socket) do
    visible = socket.assigns.visible_columns

    updated =
      if MapSet.member?(visible, column_id) do
        MapSet.delete(visible, column_id)
      else
        MapSet.put(visible, column_id)
      end

    {:noreply,
     socket
     |> assign(:visible_columns, updated)
     |> push_event("store-column-prefs", %{visible: MapSet.to_list(updated)})}
  end

  @impl true
  def handle_event("reset-columns", _params, socket) do
    {:noreply,
     socket
     |> assign(:visible_columns, @default_visible)
     |> push_event("store-column-prefs", %{visible: MapSet.to_list(@default_visible)})}
  end

  @impl true
  def handle_event("restore-column-prefs", %{"visible" => visible_list}, socket)
      when is_list(visible_list) do
    valid_ids = MapSet.new(@toggleable_columns, & &1.id)

    restored =
      visible_list
      |> Enum.filter(&MapSet.member?(valid_ids, &1))
      |> MapSet.new()

    {:noreply, assign(socket, :visible_columns, restored)}
  end

  def handle_event("restore-column-prefs", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-column-menu", _params, socket) do
    {:noreply, assign(socket, :column_menu_open, not socket.assigns.column_menu_open)}
  end

  @impl true
  def handle_event("close-column-menu", _params, socket) do
    {:noreply, assign(socket, :column_menu_open, false)}
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
            <p class="hero-engine">
              Engine: <strong><%= @payload[:agent_engine] || "claude" %></strong>
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
                <% update = update_payload(entry) %>
                <% runtime_health = runtime_health_status(entry, @now) %>
                <div class="task-card-header">
                  <div class="task-card-id-row">
                    <span class="task-card-id"><%= entry.issue_identifier %></span>
                    <span class={state_badge_class(entry.state)}>
                      <%= entry.state %>
                    </span>
                    <span class={runtime_health_badge_class(runtime_health)}>
                      <%= runtime_health_label(runtime_health) %>
                    </span>
                  </div>
                  <span class={"task-card-priority #{priority_class(entry.priority)}"}>
                    <%= priority_label(entry[:priority]) %>
                  </span>
                </div>

                <h3 class="task-card-title"><%= entry[:title] || entry.issue_identifier %></h3>
                <p class="task-card-owner muted">
                  Assignee · <span class="mono"><%= assignee_label(entry[:assignee_id]) %></span>
                </p>

                <div class="task-card-meta-groups">
                  <section class="meta-group">
                    <p class="meta-group-label">Runtime</p>
                    <div class="meta-group-values">
                      <span class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                      <span class="muted">Profile · <%= runtime_label(entry.runtime) %></span>
                      <span class="muted">Updated · <%= format_relative_time(entry[:updated_at] || entry[:started_at], @now) %></span>
                    </div>
                  </section>

                  <section class="meta-group">
                    <p class="meta-group-label">Tokens</p>
                    <div class="meta-group-values numeric">
                      <span>Total · <%= format_int(entry.tokens.total_tokens) %></span>
                      <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                    </div>
                  </section>

                  <section class="meta-group">
                    <p class="meta-group-label">Agent</p>
                    <div class="meta-group-values">
                      <span class={agent_badge_class(agent_field(entry.agent, :engine))}>
                        <%= display_agent_engine(agent_field(entry.agent, :engine)) %>
                      </span>
                      <span class="muted">provider · <span class="mono"><%= display_or_na(agent_field(entry.agent, :provider)) %></span></span>
                      <span class="muted">model · <span class="mono"><%= display_or_na(agent_field(entry.agent, :model)) %></span></span>
                    </div>
                  </section>
                </div>

                <div class="task-card-update">
                  <p class="task-card-update-label muted">Latest update</p>
                  <span class="event-text muted" title={update.full}><%= update.preview %></span>
                  <%= if update.truncated? do %>
                    <details class="update-disclosure">
                      <summary>View full update</summary>
                      <p class="update-disclosure-body mono"><%= update.full %></p>
                    </details>
                  <% end %>
                  <span class="muted event-meta">
                    <%= entry.last_event || "n/a" %>
                    <%= if entry.last_event_at do %>
                      · <%= format_relative_time(entry.last_event_at, @now) %>
                    <% end %>
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

        <section class="section-card" id="running-sessions" phx-hook="ColumnPrefs">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
            <div class="column-prefs-controls">
              <button
                type="button"
                class="subtle-button"
                phx-click="toggle-column-menu"
              >
                Columns
              </button>
              <%= if @column_menu_open do %>
                <div class="column-prefs-menu" phx-click-away="close-column-menu">
                  <p class="column-prefs-heading">Toggle columns</p>
                  <%= for col <- @toggleable_columns do %>
                    <label class="column-prefs-item">
                      <input
                        type="checkbox"
                        checked={MapSet.member?(@visible_columns, col.id)}
                        phx-click="toggle-column"
                        phx-value-column={col.id}
                      />
                      <span><%= col.label %></span>
                    </label>
                  <% end %>
                  <button
                    type="button"
                    class="column-prefs-reset"
                    phx-click="reset-columns"
                  >
                    Reset to defaults
                  </button>
                </div>
              <% end %>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 16rem;" />
                  <col style="width: 8rem;" />
                  <%= if col_visible?(@visible_columns, "runtime_health") do %><col style="width: 8.5rem;" /><% end %>
                  <%= if col_visible?(@visible_columns, "runtime") do %><col style="width: 14rem;" /><% end %>
                  <%= if col_visible?(@visible_columns, "agent") do %><col style="width: 13rem;" /><% end %>
                  <%= if col_visible?(@visible_columns, "tokens") do %><col style="width: 10rem;" /><% end %>
                  <%= if col_visible?(@visible_columns, "update") do %><col /><% end %>
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <%= if col_visible?(@visible_columns, "runtime_health") do %><th>Runtime health</th><% end %>
                    <%= if col_visible?(@visible_columns, "runtime") do %><th>Runtime</th><% end %>
                    <%= if col_visible?(@visible_columns, "agent") do %><th>Agent</th><% end %>
                    <%= if col_visible?(@visible_columns, "tokens") do %><th>Tokens</th><% end %>
                    <%= if col_visible?(@visible_columns, "update") do %><th>Latest update</th><% end %>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <span class="issue-title"><%= entry[:title] || "Untitled issue" %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <%= if col_visible?(@visible_columns, "runtime_health") do %>
                      <td>
                        <% runtime_health = runtime_health_status(entry, @now) %>
                        <span class={runtime_health_badge_class(runtime_health)}>
                          <%= runtime_health_label(runtime_health) %>
                        </span>
                      </td>
                    <% end %>
                    <%= if col_visible?(@visible_columns, "runtime") do %>
                      <td>
                        <div class="session-stack metadata-stack">
                          <span class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                          <span class="muted">Profile · <%= runtime_label(entry.runtime) %></span>
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
                    <% end %>
                    <%= if col_visible?(@visible_columns, "agent") do %>
                      <td>
                        <div class="agent-stack metadata-stack">
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
                    <% end %>
                    <%= if col_visible?(@visible_columns, "tokens") do %>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    <% end %>
                    <%= if col_visible?(@visible_columns, "update") do %>
                      <td>
                        <% update = update_payload(entry) %>
                        <div class="detail-stack update-stack">
                          <span class="event-text muted" title={update.full}><%= update.preview %></span>
                          <%= if update.truncated? do %>
                            <details class="update-disclosure">
                              <summary>View full update</summary>
                              <p class="update-disclosure-body mono"><%= update.full %></p>
                            </details>
                          <% end %>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <%= format_relative_time(entry.last_event_at, @now) %>
                            <% end %>
                          </span>
                        </div>
                      </td>
                    <% end %>
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

  defp col_visible?(visible_columns, column_id) do
    MapSet.member?(visible_columns, column_id)
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

  defp runtime_label(%{effective: effective}) when is_binary(effective) and effective != "", do: effective
  defp runtime_label(%{requested: requested}) when is_binary(requested) and requested != "", do: requested
  defp runtime_label(_runtime), do: "n/a"

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

  defp update_payload(entry) do
    full =
      case entry.last_message do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> display_or_na(entry.last_event)
            trimmed -> trimmed
          end

        _ ->
          display_or_na(entry.last_event)
      end

    {preview, truncated?} = truncate_copy(full, @update_preview_char_limit)
    %{full: full, preview: preview, truncated?: truncated?}
  end

  defp truncate_copy(text, limit) when is_binary(text) and is_integer(limit) and limit > 1 do
    if String.length(text) > limit do
      {String.slice(text, 0, limit - 1) <> "…", true}
    else
      {text, false}
    end
  end

  defp truncate_copy(text, _limit), do: {to_string(text), false}

  defp runtime_health_status(entry, now) do
    state = entry.state |> to_string() |> String.downcase()

    cond do
      String.contains?(state, ["blocked", "error", "failed"]) ->
        :critical

      String.contains?(state, ["queued", "pending", "retry"]) ->
        :watch

      true ->
        case seconds_since(entry.last_event_at, now) do
          nil -> :unknown
          seconds when seconds <= @runtime_health_fresh_seconds -> :healthy
          seconds when seconds <= @runtime_health_stale_seconds -> :watch
          _ -> :stale
        end
    end
  end

  defp runtime_health_label(:healthy), do: "Healthy"
  defp runtime_health_label(:watch), do: "Watch"
  defp runtime_health_label(:stale), do: "Stale"
  defp runtime_health_label(:critical), do: "Blocked"
  defp runtime_health_label(:unknown), do: "Unknown"

  defp runtime_health_badge_class(status) do
    base = "runtime-health-badge"

    case status do
      :healthy -> "#{base} runtime-health-badge-healthy"
      :watch -> "#{base} runtime-health-badge-watch"
      :stale -> "#{base} runtime-health-badge-stale"
      :critical -> "#{base} runtime-health-badge-critical"
      _ -> "#{base} runtime-health-badge-unknown"
    end
  end

  defp seconds_since(nil, _now), do: nil

  defp seconds_since(%DateTime{} = time, %DateTime{} = now) do
    max(DateTime.diff(now, time, :second), 0)
  end

  defp seconds_since(time, %DateTime{} = now) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, parsed, _offset} -> seconds_since(parsed, now)
      _ -> nil
    end
  end

  defp seconds_since(_time, _now), do: nil

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
