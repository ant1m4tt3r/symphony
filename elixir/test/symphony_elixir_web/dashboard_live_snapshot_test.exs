defmodule SymphonyElixirWeb.DashboardLiveSnapshotTest do
  use ExUnit.Case

  import Phoenix.LiveViewTest

  alias SymphonyElixir.TestSupport.Snapshot
  alias SymphonyElixirWeb.DashboardLive

  @snapshot_dir "dashboard_live_snapshots"

  describe "pr_status_cell" do
    test "snapshot: no PR status" do
      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: nil)
      assert_html_snapshot!("no_pr_status", html)
    end

    test "snapshot: CI passing, review approved" do
      pr_status = %{
        pr_url: "https://github.com/org/repo/pull/42",
        pr_number: 42,
        checks: "passing",
        review_status: "approved"
      }

      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: pr_status)
      assert_html_snapshot!("ci_passing_review_approved", html)
    end

    test "snapshot: CI failing, review changes requested" do
      pr_status = %{
        pr_url: "https://github.com/org/repo/pull/99",
        pr_number: 99,
        checks: "failing",
        review_status: "changes_requested"
      }

      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: pr_status)
      assert_html_snapshot!("ci_failing_review_changes", html)
    end

    test "snapshot: CI pending, no review" do
      pr_status = %{
        pr_url: "https://github.com/org/repo/pull/7",
        pr_number: 7,
        checks: "pending",
        review_status: nil
      }

      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: pr_status)
      assert_html_snapshot!("ci_pending_no_review", html)
    end

    test "snapshot: no checks, review pending" do
      pr_status = %{
        pr_url: "https://github.com/org/repo/pull/15",
        pr_number: 15,
        checks: nil,
        review_status: "pending"
      }

      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: pr_status)
      assert_html_snapshot!("no_checks_review_pending", html)
    end

    test "CI failing badge has danger class" do
      pr_status = %{
        pr_url: "https://github.com/org/repo/pull/1",
        pr_number: 1,
        checks: "failing",
        review_status: nil
      }

      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: pr_status)
      assert html =~ "ci-badge-failing"
      assert html =~ "CI failing"
      assert html =~ ~s(role="status")
      assert html =~ ~s(tabindex="0")
    end

    test "changes_requested badge has danger class" do
      pr_status = %{
        pr_url: "https://github.com/org/repo/pull/1",
        pr_number: 1,
        checks: nil,
        review_status: "changes_requested"
      }

      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: pr_status)
      assert html =~ "review-badge-changes"
      assert html =~ "Changes requested"
      assert html =~ ~s(role="status")
      assert html =~ ~s(tabindex="0")
    end

    test "approved badge has approved class" do
      pr_status = %{
        pr_url: "https://github.com/org/repo/pull/1",
        pr_number: 1,
        checks: nil,
        review_status: "approved"
      }

      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: pr_status)
      assert html =~ "review-badge-approved"
      assert html =~ "Approved"
    end

    test "absent pr_status renders em dash" do
      html = render_component(&DashboardLive.pr_status_cell/1, pr_status: nil)
      assert html =~ "—"
      refute html =~ "pr-status-stack"
    end
  end

  defp assert_html_snapshot!(name, html) do
    normalized =
      html
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    Snapshot.assert_snapshot!(
      Path.join(@snapshot_dir, "#{name}.snapshot.html"),
      normalized
    )
  end
end
