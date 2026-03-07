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

  test "supports multiple task label override prefixes and runtime aliases" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
    codex_bin = Path.join(test_root, "fake-codex")
    claude_bin = Path.join(test_root, "fake-claude")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.write!(claude_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(codex_bin, 0o755)
      File.chmod!(claude_bin, 0o755)

      runtime_commands = %{
        "claude" => "CLAUDE_MODE=1 #{claude_bin} app-server",
        "codex" => "CODEX_MODE=1 #{codex_bin} app-server"
      }

      for {label, expected_runtime} <- [
            {"agent=claude", "claude"},
            {"runtime:claude-code", "claude"},
            {"runtime=anthropic", "claude"},
            {"engine:codex", "codex"},
            {"engine=openai-codex", "codex"}
          ] do
        assert {:ok, selection} =
                 AgentRuntime.resolve(
                   %{labels: [label]},
                   global_runtime: nil,
                   runtime_commands: runtime_commands
                 )

        assert selection.requested_source == "task_label"
        assert selection.requested_runtime == expected_runtime
        assert selection.effective_runtime == expected_runtime
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "uses fallback command selection path when no runtime command is executable" do
    assert {:ok, selection} =
             AgentRuntime.resolve(
               %Issue{labels: []},
               global_runtime: nil,
               runtime_commands: %{
                 "claude" => "definitely-missing-claude app-server",
                 "codex" => "definitely-missing-codex app-server"
               }
             )

    assert selection.requested_runtime == "claude"
    assert selection.effective_runtime == "claude"
    assert selection.runtime_command == "definitely-missing-claude app-server"
    assert selection.runtime_fallback_reason == nil
  end

  test "returns an error when selected fallback command is non-binary" do
    assert {:error, {:missing_runtime_command, "codex"}} =
             AgentRuntime.resolve(
               %Issue{labels: ["agent:codex"]},
               global_runtime: nil,
               runtime_commands: %{"codex" => 123, "claude" => nil}
             )
  end

  test "falls back to config commands when runtime_commands option is invalid" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
    codex_bin = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(codex_bin, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(), codex_command: "#{codex_bin} app-server")

      assert {:ok, selection} =
               AgentRuntime.resolve(
                 %{},
                 global_runtime: "codex",
                 runtime_commands: :invalid
               )

      assert selection.requested_source == "workflow"
      assert selection.requested_runtime == "codex"
      assert selection.effective_runtime == "codex"
      assert selection.runtime_command == "#{codex_bin} app-server"
      assert selection.runtime_fallback_reason == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "detects available non-path executables from PATH" do
    assert {:ok, selection} =
             AgentRuntime.resolve(
               %Issue{labels: ["agent:codex"]},
               global_runtime: nil,
               runtime_commands: %{
                 "claude" => "definitely-missing-claude app-server",
                 "codex" => "sh -c true"
               }
             )

    assert selection.requested_runtime == "codex"
    assert selection.effective_runtime == "codex"
    assert selection.runtime_command == "sh -c true"
  end

  test "ignores invalid labels and override keys while honoring atom runtime overrides" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
    codex_bin = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(codex_bin, 0o755)

      assert {:ok, selection} =
               AgentRuntime.resolve(
                 %{labels: ["runtime:unknown", "owner:platform"]},
                 global_runtime: :codex,
                 default_runtime: 123,
                 runtime_commands: %{
                   :codex => "#{codex_bin} app-server",
                   123 => "ignored-command"
                 }
               )

      assert selection.requested_source == "workflow"
      assert selection.requested_runtime == "codex"
      assert selection.effective_runtime == "codex"
      assert selection.runtime_command == "#{codex_bin} app-server"
    after
      File.rm_rf(test_root)
    end
  end

  test "falls back when requested path command exists but is not executable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
    codex_bin = Path.join(test_root, "fake-codex")
    non_exec_claude = Path.join(test_root, "fake-claude-nonexec")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_bin, "#!/usr/bin/env sh\nexit 0\n")
      File.write!(non_exec_claude, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(codex_bin, 0o755)
      File.chmod!(non_exec_claude, 0o644)

      assert {:ok, selection} =
               AgentRuntime.resolve(
                 :not_an_issue_map,
                 global_runtime: nil,
                 default_runtime: nil,
                 runtime_commands: %{
                   "claude" => "#{non_exec_claude} app-server",
                   "codex" => "#{codex_bin} app-server"
                 }
               )

      assert selection.requested_source == "default"
      assert selection.requested_runtime == "claude"
      assert selection.effective_runtime == "codex"
      assert selection.runtime_command == "#{codex_bin} app-server"
      assert selection.runtime_fallback_reason =~ "fell back to codex"
    after
      File.rm_rf(test_root)
    end
  end

  test "handles env-only commands by taking deterministic fallback command selection path" do
    assert {:ok, selection} =
             AgentRuntime.resolve(
               %Issue{labels: ["agent:codex"]},
               global_runtime: nil,
               runtime_commands: %{
                 "claude" => "CLAUDE_ONLY=1",
                 "codex" => "CODEX_ONLY=1"
               }
             )

    assert selection.requested_runtime == "codex"
    assert selection.effective_runtime == "codex"
    assert selection.runtime_command == "CODEX_ONLY=1"
    assert selection.runtime_fallback_reason == nil
  end

  test "returns an error when fallback command is blank" do
    assert {:error, {:missing_runtime_command, "codex"}} =
             AgentRuntime.resolve(
               %Issue{labels: ["agent:codex"]},
               global_runtime: nil,
               runtime_commands: %{
                 "claude" => nil,
                 "codex" => "   "
               }
             )
  end

  test "treats empty executable tokens and missing executable paths as unavailable" do
    missing_path = Path.join(System.tmp_dir!(), "symphony-agent-runtime-missing-#{System.unique_integer([:positive])}")

    assert {:ok, selection} =
             AgentRuntime.resolve(
               %Issue{labels: []},
               global_runtime: nil,
               runtime_commands: %{
                 "claude" => "\"\" foo",
                 "codex" => "#{missing_path} app-server"
               }
             )

    assert selection.requested_runtime == "claude"
    assert selection.effective_runtime == "claude"
    assert selection.runtime_command == "\"\" foo"
    assert selection.runtime_fallback_reason == nil
  end
end
