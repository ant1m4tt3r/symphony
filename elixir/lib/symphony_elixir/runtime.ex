defmodule SymphonyElixir.Runtime do
  @moduledoc """
  Runtime adapter boundary for agent execution.

  Defines the contract that all runtime adapters (Claude, Codex, etc.) must
  satisfy for session lifecycle and turn execution, and dispatches through
  the configured adapter implementation.
  """

  alias SymphonyElixir.Runtime.AppServer

  @type session :: AppServer.session()

  @type runtime_selection :: %{
          requested_runtime: String.t(),
          requested_source: String.t(),
          effective_runtime: String.t(),
          runtime_command: String.t(),
          runtime_fallback_reason: String.t() | nil
        }

  @callback start_session(Path.t(), runtime_selection() | nil) ::
              {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @doc """
  Starts a runtime session in the given workspace using the resolved runtime selection.
  """
  @spec start_session(Path.t(), runtime_selection() | nil) :: {:ok, session()} | {:error, term()}
  defdelegate start_session(workspace, runtime_selection), to: AppServer

  @doc """
  Executes a single turn within an active session.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run_turn(session, prompt, issue, opts \\ []), to: AppServer

  @doc """
  Stops and cleans up a runtime session.
  """
  @spec stop_session(session()) :: :ok
  defdelegate stop_session(session), to: AppServer
end
