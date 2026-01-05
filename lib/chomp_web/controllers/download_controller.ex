defmodule ChompWeb.DownloadController do
  use ChompWeb, :controller

  def show(conn, %{"token" => token}) do
    case Chomp.Video.get_and_delete(token) do
      {:ok, {filename, data}} ->
        conn
        |> put_resp_content_type("video/mp4")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("content-length", "#{byte_size(data)}")
        |> send_resp(200, data)

      :error ->
        conn
        |> put_flash(:error, "Video not found. It was likely already downloaded.")
        |> redirect(to: ~p"/")
    end
  end
end
