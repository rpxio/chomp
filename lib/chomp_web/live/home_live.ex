defmodule ChompWeb.HomeLive do
  use ChompWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       url: "",
       state: :idle,
       status: nil,
       token: nil,
       file_info: nil,
       error: nil,
       error_details: nil,
       show_details: false
     )}
  end

  def render(assigns) do
    ~H"""
    <.flash kind={:error} flash={@flash} />
    <div class="flex flex-col items-center justify-center min-h-[60vh] px-4">
      <%= case @state do %>
        <% state when state in [:idle, :processing, :error] -> %>
          <p class={["text-sm mb-4", @state == :error && "text-error", @state != :error && "text-base-content/70"]}>
            <%= cond do %>
              <% @state == :idle -> %>
                input the video URL you want to share
              <% @state == :processing -> %>
                {@status}
              <% @state == :error -> %>
                {@error}
            <% end %>
          </p>
          <%= if @state == :error && @error_details do %>
            <div class="mb-4 text-xs">
              <button type="button" phx-click="toggle-details" class="text-base-content/50 underline">
                <%= if @show_details, do: "hide details", else: "show details" %>
              </button>
              <%= if @show_details do %>
                <pre class="mt-2 p-2 bg-base-300 rounded text-left max-w-md overflow-x-auto text-base-content/70"><%= @error_details %></pre>
              <% end %>
            </div>
          <% end %>
          <form phx-submit="process" class="flex gap-2 w-full max-w-md">
            <input
              type="url"
              name="url"
              id="url-input"
              value={@url}
              placeholder="https://..."
              class="input input-bordered flex-1 text-base"
              disabled={@state == :processing}
              required
            />
            <button type="submit" class="btn btn-primary" disabled={@state == :processing}>
              <%= if @state == :processing do %>
                <span class="loading loading-spinner loading-sm"></span>
              <% else %>
                Go
              <% end %>
            </button>
          </form>

        <% :ready -> %>
          <div class="text-center">
            <p class="text-sm text-base-content/70 mb-4">ready to download</p>
            <%= if @file_info do %>
              <p class="text-xs text-base-content/50 mb-4">{elem(@file_info, 0)} ({format_size(elem(@file_info, 1))})</p>
            <% end %>
            <a href={~p"/download/#{@token}"} class="btn btn-primary">Download</a>
            <p class="mt-4 text-base-content/30">•••</p>
            <p class="mt-2">
              <.link navigate={~p"/"} class="text-sm text-primary underline">Start over</.link>
            </p>
          </div>
      <% end %>
    </div>
    """
  end

  def handle_event("process", %{"url" => url}, socket) do
    lv = self()

    Task.start(fn ->
      result =
        Chomp.Video.process(url, fn msg ->
          send(lv, {:status, msg})
        end)

      send(lv, {:result, result})
    end)

    {:noreply, assign(socket, state: :processing, status: "Starting...", url: url)}
  end

  def handle_event("toggle-details", _, socket) do
    {:noreply, assign(socket, show_details: !socket.assigns.show_details)}
  end

  def handle_info({:status, msg}, socket) do
    {:noreply, assign(socket, status: msg)}
  end

  def handle_info({:result, {:ok, token}}, socket) do
    file_info = Chomp.Video.get_info(token)

    {:noreply,
     assign(socket,
       state: :ready,
       token: token,
       file_info: elem(file_info, 1)
     )}
  end

  def handle_info({:result, {:error, reason}}, socket) do
    {simple_error, details} = simplify_error(reason)

    {:noreply,
     socket
     |> assign(state: :error, error: simple_error, error_details: details, show_details: false)
     |> push_event("select-input", %{id: "url-input"})}
  end

  defp simplify_error(reason) when is_binary(reason) do
    cond do
      # YouTube bot detection
      String.contains?(reason, "Sign in to confirm you're not a bot") ->
        {"This video requires authentication (bot detection)", reason}

      # Instagram login required / bot detection
      String.contains?(reason, "locked behind the login page") or
          String.contains?(reason, "Login required") ->
        {"This video requires login (bot detection)", reason}

      # Video unavailable/private
      String.contains?(reason, "Video unavailable") or String.contains?(reason, "Private video") ->
        {"Video is unavailable or private", reason}

      # File size limit (keep as-is, no details needed)
      String.contains?(reason, "too large") ->
        {reason, nil}

      # yt-dlp not found
      String.contains?(reason, "enoent") or String.contains?(reason, "not found") ->
        {"Video downloader not available", reason}

      # Network errors
      String.contains?(reason, "URLError") or String.contains?(reason, "timed out") ->
        {"Network error - please try again", reason}

      # Unsupported URL
      String.contains?(reason, "Unsupported URL") ->
        {"Unsupported video URL", reason}

      # Generic prefixed errors - show simple message, details have the rest
      String.starts_with?(reason, "Failed to get video info:") ->
        {"Failed to get video info", String.replace(reason, "Failed to get video info: ", "")}

      String.starts_with?(reason, "Download failed:") ->
        {"Download failed", String.replace(reason, "Download failed: ", "")}

      String.starts_with?(reason, "Processing failed") ->
        {"Processing failed", reason}

      # Any long error gets simplified
      String.length(reason) > 50 ->
        {"Something went wrong", reason}

      # Short errors pass through as-is
      true ->
        {reason, nil}
    end
  end

  # Handle non-string errors (erlang errors, exceptions, etc)
  defp simplify_error(reason) do
    details = inspect(reason, pretty: true, limit: 500)
    {"Something went wrong", details}
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
