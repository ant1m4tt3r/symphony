defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Resolves runtime selection for an issue and provides deterministic fallback.
  """

  import Bitwise, only: [&&&: 2]

  alias SymphonyElixir.{Config, Linear.Issue}

  @default_runtime "claude"
  @supported_runtimes ["claude", "codex"]

  @type selection :: %{
          requested_runtime: String.t(),
          requested_source: String.t(),
          effective_runtime: String.t(),
          runtime_command: String.t(),
          runtime_fallback_reason: String.t() | nil
        }

  @spec resolve(Issue.t() | map(), keyword()) :: {:ok, selection()} | {:error, term()}
  def resolve(issue, opts \\ []) do
    global_runtime =
      opts
      |> Keyword.get(:global_runtime, Config.agent_runtime_override())
      |> normalize_runtime()

    default_runtime =
      opts
      |> Keyword.get(:default_runtime, @default_runtime)
      |> normalize_runtime()
      |> fallback_runtime()

    issue_runtime = issue_runtime_override(issue)
    {requested_runtime, requested_source} = requested_runtime(issue_runtime, global_runtime, default_runtime)

    commands = runtime_commands(opts)

    candidate_runtimes =
      [
        requested_runtime,
        global_runtime,
        default_runtime
        | @supported_runtimes
      ]
      |> Enum.map(&normalize_runtime/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {effective_runtime, runtime_command, fallback_reason} =
      choose_effective_runtime(candidate_runtimes, commands, requested_runtime)

    if is_binary(runtime_command) and String.trim(runtime_command) != "" do
      {:ok,
       %{
         requested_runtime: requested_runtime,
         requested_source: requested_source,
         effective_runtime: effective_runtime,
         runtime_command: runtime_command,
         runtime_fallback_reason: fallback_reason
       }}
    else
      {:error, {:missing_runtime_command, effective_runtime}}
    end
  end

  defp requested_runtime(issue_runtime, global_runtime, default_runtime) do
    cond do
      is_binary(issue_runtime) ->
        {issue_runtime, "task_label"}

      is_binary(global_runtime) ->
        {global_runtime, "workflow"}

      true ->
        {default_runtime, "default"}
    end
  end

  defp choose_effective_runtime(candidate_runtimes, commands, requested_runtime) do
    selected =
      Enum.find_value(candidate_runtimes, fn runtime ->
        command = Map.get(commands, runtime)

        if command_available?(command) do
          {runtime, command}
        else
          nil
        end
      end)

    case selected do
      {runtime, command} ->
        fallback_reason =
          if runtime == requested_runtime do
            nil
          else
            "selected runtime #{requested_runtime} unavailable; fell back to #{runtime}"
          end

        {runtime, command, fallback_reason}

      nil ->
        command = Map.get(commands, requested_runtime) || Map.get(commands, @default_runtime) || Config.codex_command()
        {requested_runtime, command, nil}
    end
  end

  defp runtime_commands(opts) do
    base = %{
      "claude" => Config.claude_command(),
      "codex" => Config.codex_command()
    }

    case Keyword.get(opts, :runtime_commands) do
      nil ->
        base

      %{} = overrides ->
        overrides
        |> Enum.reduce(base, fn {runtime, command}, acc ->
          case normalize_runtime(runtime) do
            nil -> acc
            normalized -> Map.put(acc, normalized, command)
          end
        end)

      _ ->
        base
    end
  end

  defp issue_runtime_override(%Issue{labels: labels}), do: issue_runtime_override(labels)
  defp issue_runtime_override(%{labels: labels}) when is_list(labels), do: issue_runtime_override(labels)

  defp issue_runtime_override(labels) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.sort()
    |> Enum.find_value(&runtime_from_label/1)
  end

  defp issue_runtime_override(_), do: nil

  defp runtime_from_label("agent:" <> runtime), do: normalize_runtime(runtime)
  defp runtime_from_label("agent=" <> runtime), do: normalize_runtime(runtime)
  defp runtime_from_label("runtime:" <> runtime), do: normalize_runtime(runtime)
  defp runtime_from_label("runtime=" <> runtime), do: normalize_runtime(runtime)
  defp runtime_from_label("engine:" <> runtime), do: normalize_runtime(runtime)
  defp runtime_from_label("engine=" <> runtime), do: normalize_runtime(runtime)
  defp runtime_from_label(_label), do: nil

  defp command_available?(command) when is_binary(command) do
    executable =
      command
      |> String.trim()
      |> OptionParser.split()
      |> Enum.drop_while(&env_assignment_token?/1)
      |> List.first()

    executable_available?(executable)
  end

  defp command_available?(_command), do: false

  defp executable_available?(nil), do: false

  defp executable_available?(executable) when is_binary(executable) do
    cond do
      executable == "" ->
        false

      String.contains?(executable, "/") ->
        executable_path_available?(executable)

      true ->
        not is_nil(System.find_executable(executable))
    end
  end

  defp executable_available?(_), do: false

  defp executable_path_available?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end

  defp env_assignment_token?(token) when is_binary(token) do
    String.match?(token, ~r/^[A-Za-z_][A-Za-z0-9_]*=.*/)
  end

  defp env_assignment_token?(_token), do: false

  defp normalize_runtime(runtime) when is_binary(runtime) do
    case runtime |> String.trim() |> String.downcase() do
      "claude" -> "claude"
      "claude-code" -> "claude"
      "anthropic" -> "claude"
      "codex" -> "codex"
      "openai-codex" -> "codex"
      _ -> nil
    end
  end

  defp normalize_runtime(runtime) when is_atom(runtime) do
    runtime
    |> Atom.to_string()
    |> normalize_runtime()
  end

  defp normalize_runtime(_runtime), do: nil

  defp fallback_runtime(runtime) when is_binary(runtime), do: runtime
  defp fallback_runtime(_runtime), do: @default_runtime
end
