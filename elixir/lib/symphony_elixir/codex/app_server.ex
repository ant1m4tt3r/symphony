defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Legacy alias for `SymphonyElixir.Runtime.AppServer`.

  Delegates all calls to the runtime-agnostic app-server implementation.
  Existing code that references `Codex.AppServer` continues to work unchanged.
  """

  alias SymphonyElixir.Runtime.AppServer, as: RuntimeAppServer

  @type session :: RuntimeAppServer.session()

  defdelegate run(workspace, prompt, issue, opts \\ []), to: RuntimeAppServer
  defdelegate start_session(workspace, runtime_selection \\ nil), to: RuntimeAppServer
  defdelegate run_turn(session, prompt, issue, opts \\ []), to: RuntimeAppServer
  defdelegate stop_session(session), to: RuntimeAppServer
end
