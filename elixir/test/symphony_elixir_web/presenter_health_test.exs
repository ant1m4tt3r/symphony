defmodule SymphonyElixirWeb.PresenterHealthTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Presenter

  describe "health_payload/3" do
    test "returns streaming when last update is recent" do
      now = DateTime.utc_now()
      recent_time = DateTime.add(now, -30, :second)
      stall_timeout = 300_000

      result = Presenter.health_payload(recent_time, now, stall_timeout)

      assert result.status == :streaming
      assert result.last_update_age_ms == 30_000
      assert result.stall_timeout_ms == stall_timeout
    end

    test "returns idle when last update is between half and full timeout" do
      now = DateTime.utc_now()
      idle_time = DateTime.add(now, -200_000, :millisecond)
      stall_timeout = 300_000

      result = Presenter.health_payload(idle_time, now, stall_timeout)

      assert result.status == :idle
      assert result.last_update_age_ms == 200_000
      assert result.stall_timeout_ms == stall_timeout
    end

    test "returns stalled when last update exceeds timeout" do
      now = DateTime.utc_now()
      stale_time = DateTime.add(now, -400_000, :millisecond)
      stall_timeout = 300_000

      result = Presenter.health_payload(stale_time, now, stall_timeout)

      assert result.status == :stalled
      assert result.last_update_age_ms == 400_000
      assert result.stall_timeout_ms == stall_timeout
    end

    test "returns streaming at exactly half timeout boundary" do
      now = DateTime.utc_now()
      boundary_time = DateTime.add(now, -150_000, :millisecond)
      stall_timeout = 300_000

      result = Presenter.health_payload(boundary_time, now, stall_timeout)

      assert result.status == :streaming
    end

    test "returns idle at exactly half timeout boundary" do
      now = DateTime.utc_now()
      boundary_time = DateTime.add(now, -150_001, :millisecond)
      stall_timeout = 300_000

      result = Presenter.health_payload(boundary_time, now, stall_timeout)

      assert result.status == :idle
    end

    test "returns idle at exactly timeout boundary" do
      now = DateTime.utc_now()
      boundary_time = DateTime.add(now, -300_000, :millisecond)
      stall_timeout = 300_000

      result = Presenter.health_payload(boundary_time, now, stall_timeout)

      assert result.status == :idle
    end

    test "returns stalled just after timeout boundary" do
      now = DateTime.utc_now()
      boundary_time = DateTime.add(now, -300_001, :millisecond)
      stall_timeout = 300_000

      result = Presenter.health_payload(boundary_time, now, stall_timeout)

      assert result.status == :stalled
    end

    test "returns unknown when last_timestamp is nil" do
      now = DateTime.utc_now()

      result = Presenter.health_payload(nil, now, 300_000)

      assert result.status == :unknown
      assert result.last_update_age_ms == nil
      assert result.stall_timeout_ms == 300_000
    end

    test "returns unknown when stall_timeout is not an integer" do
      now = DateTime.utc_now()
      recent_time = DateTime.add(now, -30, :second)

      result = Presenter.health_payload(recent_time, now, "invalid")

      assert result.status == :unknown
    end

    test "returns unknown when last_timestamp is not a DateTime" do
      now = DateTime.utc_now()

      result = Presenter.health_payload(:invalid, now, 300_000)

      assert result.status == :unknown
    end
  end
end
