defmodule Lavash.Overlay.RenderGenerator do
  @moduledoc """
  Behaviour for overlay render generators.

  Each overlay type (modal, flyover, etc.) implements this behaviour to generate
  its render/1 function. The component compiler calls the registered generator
  without needing to know the specifics of each overlay type.
  """

  @doc """
  Generates the render/1 function AST for the overlay component.

  Receives the module being compiled and returns quoted code that defines
  the render/1 function with the overlay chrome and content.
  """
  @callback generate(module :: module()) :: Macro.t()

  @doc """
  Returns the path to the helpers module that should trigger recompilation.
  """
  @callback helpers_path() :: String.t()
end
