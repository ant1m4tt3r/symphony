defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Legacy alias for `SymphonyElixir.Runtime.DynamicTool`.

  Delegates all calls to the runtime-agnostic dynamic tool implementation.
  Existing code that references `Codex.DynamicTool` continues to work unchanged.
  """

  alias SymphonyElixir.Runtime.DynamicTool, as: RuntimeDynamicTool

  defdelegate execute(tool, arguments, opts \\ []), to: RuntimeDynamicTool
  defdelegate tool_specs(), to: RuntimeDynamicTool
end
