defmodule DemoWeb.Account.SettingsLive do
  use DemoWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <a href={~p"/account"} class="btn btn-ghost btn-sm">&larr;</a>
        <h1 class="text-2xl font-bold">Settings</h1>
      </div>

      <%= if @current_user do %>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Account Details</h2>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Email</span>
              </label>
              <input type="email" value={@current_user.email} class="input input-bordered" disabled />
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Password</h2>
            <p class="text-base-content/70">Change your password or reset it via email.</p>
            <div class="card-actions mt-4">
              <button class="btn btn-outline" disabled>Change Password</button>
            </div>
          </div>
        </div>
      <% else %>
        <div class="card bg-base-200">
          <div class="card-body text-center">
            <p class="text-base-content/70">Please sign in to manage your settings.</p>
            <div class="card-actions justify-center mt-4">
              <a href={~p"/sign-in"} class="btn btn-primary">Sign In</a>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
