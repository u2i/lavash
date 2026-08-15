defmodule DemoWeb.SourceLink do
  @moduledoc """
  "View source" links for demo pages: an `on_mount` hook derives the
  GitHub URL (main branch) for the mounted LiveView's own source file
  and assigns it as `:source_url`; layouts render it as a floating
  pill so every demo page links to its code with no per-page wiring.
  """

  import Phoenix.Component

  @repo "https://github.com/u2i/lavash/blob/main/"

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :source_url, github_url(socket.view))}
  end

  @doc """
  The GitHub main-branch URL for a module's source file, or nil when
  the path can't be resolved to the repo layout.
  """
  def github_url(module) do
    with source when is_list(source) <- module.module_info(:compile)[:source],
         path = to_string(source),
         [_, rel] <- String.split(path, ~r{/demo/(?=lib/)}, parts: 2) do
      @repo <> "demo/" <> rel
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
