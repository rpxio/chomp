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
       error: nil
     )}
  end

  def render(assigns) do
    ~H"""
    <.flash kind={:error} flash={@flash} />
    <div class="flex flex-col items-center justify-center min-h-[60vh]">
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
          <form phx-submit="process" class="flex gap-2 w-full max-w-md">
            <input
              type="url"
              name="url"
              id="url-input"
              value={@url}
              placeholder="https://..."
              class="input input-bordered flex-1"
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
    {:noreply,
     socket
     |> assign(state: :error, error: reason)
     |> push_event("select-input", %{id: "url-input"})}
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
