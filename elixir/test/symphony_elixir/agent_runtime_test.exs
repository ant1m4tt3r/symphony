defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Linear.Issue

  test "defaults to claude and falls back to codex when claude is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
    codex_bin = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(codex_bin, 0o755)

      assert {:ok, selection} =
               AgentRuntime.resolve(
                 %Issue{labels: []},
                 global_runtime: nil,
                 runtime_commands: %{
                   "claude" => "definitely-missing-claude app-server",
                   "codex" => "#{codex_bin} app-server"
                 }
               )

      assert selection.requested_runtime == "claude"
      assert selection.requested_source == "default"
      assert selection.effective_runtime == "codex"
      assert selection.runtime_command == "#{codex_bin} app-server"
      assert selection.runtime_fallback_reason =~ "fell back to codex"
    after
      File.rm_rf(test_root)
    end
  end

  test "task label override wins over workflow runtime setting" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
    codex_bin = Path.join(test_root, "fake-codex")
    claude_bin = Path.join(test_root, "fake-claude")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.write!(claude_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(codex_bin, 0o755)
      File.chmod!(claude_bin, 0o755)

      assert {:ok, selection} =
               AgentRuntime.resolve(
                 %Issue{labels: ["agent:codex"]},
                 global_runtime: "claude",
                 runtime_commands: %{
                   "claude" => "#{claude_bin} app-server",
                   "codex" => "#{codex_bin} app-server"
                 }
               )

      assert selection.requested_runtime == "codex"
      assert selection.requested_source == "task_label"
      assert selection.effective_runtime == "codex"
      assert selection.runtime_command == "#{codex_bin} app-server"
      assert selection.runtime_fallback_reason == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow runtime setting is used when no task override exists" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
    codex_bin = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(codex_bin, 0o755)

      assert {:ok, selection} =
               AgentRuntime.resolve(
                 %Issue{labels: []},
                 global_runtime: "codex",
                 runtime_commands: %{
                   "claude" => "definitely-missing-claude app-server",
                   "codex" => "#{codex_bin} app-server"
                 }
               )

      assert selection.requested_runtime == "codex"
      assert selection.requested_source == "workflow"
      assert selection.effective_runtime == "codex"
      assert selection.runtime_command == "#{codex_bin} app-server"
      assert selection.runtime_fallback_reason == nil
    after
      File.rm_rf(test_root)
    end
  end
end
