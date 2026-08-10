defmodule Lavash.Component.CompilerHelpers do
  @moduledoc """
  Shared compiler utilities for Lavash components.
  """

  @doc """
  Gets the target directory for colocated hooks/JS.

  Matches Phoenix's logic for the target directory, checking the
  `:phoenix_live_view` config for `:colocated_js` settings.
  """
  def get_target_dir do
    default = Path.join(Mix.Project.build_path(), "phoenix-colocated")
    app = to_string(Mix.Project.config()[:app])

    Application.get_env(:phoenix_live_view, :colocated_js, [])
    |> Keyword.get(:target_directory, default)
    |> Path.join(app)
  end

  @doc """
  Whether an Ash resource module is compiled and available.

  Uses `Code.ensure_compiled/1` (which waits for parallel compilation to
  finish) rather than `Code.ensure_loaded?/1`. Safe for use from transformers
  because Ash resources never depend on Lavash LiveViews/Components — no
  circular-dependency risk.
  """
  def resource_available?(resource) do
    match?({:module, _}, Code.ensure_compiled(resource)) and
      function_exported?(resource, :spark_dsl_config, 0)
  end
end
