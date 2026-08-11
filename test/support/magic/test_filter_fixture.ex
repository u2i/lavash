defmodule Lavash.Test.Magic.FilterLive do
  @moduledoc """
  Fixture: URL-backed filters driven through `phx-change` setter forms
  (the /demos/products shape) — a text input and two selects, each a
  form with a single input named "value" targeting an auto-generated
  `set_*` action.

  Exercises the input half of optimistic actions: the phx-change
  interception must run the transpiled setter (state delta + derives +
  **URL sync**) immediately, while Phoenix's own delegate pushes the
  debounced server event. Before that interception existed, these
  filters updated server state but the URL never changed — the
  URL-state contract (shareable/bookmarkable) silently broke for any
  page driving setters from inputs instead of clicks.
  """
  use Lavash.LiveView

  state :search, :string, from: :url, default: "", setter: true
  state :flag, :boolean, from: :url, default: nil, setter: true
  state :min, :integer, from: :url, default: nil, setter: true

  calculate :flag_text, rx(if(@flag == nil, do: "unset", else: "#{@flag}"))
  calculate :min_text, rx(if(@min == nil, do: "unset", else: "#{@min}"))

  template do
    ~H"""
    <div>
      <form phx-change="set_search">
        <input id="search" type="text" name="value" value={@search} phx-debounce="150" />
      </form>

      <form phx-change="set_flag">
        <select id="flag" name="value">
          <option value="" selected={@flag == nil}>All</option>
          <option value="true" selected={@flag == true}>Yes</option>
          <option value="false" selected={@flag == false}>No</option>
        </select>
      </form>

      <form phx-change="set_min">
        <select id="min" name="value">
          <option value="" selected={@min == nil}>Any</option>
          <option :for={n <- [1, 2, 3]} value={n} selected={@min == n}>{n}+</option>
        </select>
      </form>

      <p>search: <span id="s-search">{@search}</span></p>
      <p>flag: <span id="s-flag">{@flag_text}</span></p>
      <p>min: <span id="s-min">{@min_text}</span></p>
    </div>
    """
  end
end
