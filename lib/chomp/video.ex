defmodule Chomp.Video do
  @moduledoc """
  Video downloading with yt-dlp.
  Downloads at 720p max, stores in memory (ETS) for one-time download.
  """

  use GenServer
  require Logger

  @table :video_store
  @temp_dir System.tmp_dir!()

  # Limits
  @max_filesize_bytes 100 * 1024 * 1024
  @ttl_ms :timer.minutes(10)
  @cleanup_interval_ms :timer.minutes(1)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @doc """
  Process a video URL. Returns {:ok, token} or {:error, reason}.
  The token can be used to download the processed video.
  """
  def process(url, progress_callback \\ fn _msg -> :ok end) do
    GenServer.call(__MODULE__, {:process, url, progress_callback}, :infinity)
  end

  @doc """
  Get video data by token. Returns {:ok, {filename, binary}} or :error.
  Deletes the data after retrieval (one-time download).
  """
  def get_and_delete(token) do
    case :ets.lookup(@table, token) do
      [{^token, filename, data, _timestamp}] ->
        :ets.delete(@table, token)
        {:ok, {filename, data}}

      [] ->
        :error
    end
  end

  @doc """
  Get video info without deleting (for displaying file size before download).
  """
  def get_info(token) do
    case :ets.lookup(@table, token) do
      [{^token, filename, data, _timestamp}] ->
        {:ok, {filename, byte_size(data)}}

      [] ->
        :error
    end
  end

  @doc """
  Get stats about stored videos for monitoring.
  """
  def stats do
    entries = :ets.tab2list(@table)
    now = System.monotonic_time(:millisecond)

    videos =
      Enum.map(entries, fn {token, filename, data, timestamp} ->
        %{
          token: String.slice(token, 0, 8) <> "...",
          filename: filename,
          size_mb: Float.round(byte_size(data) / 1_048_576, 2),
          age_seconds: div(now - timestamp, 1000)
        }
      end)

    total_bytes = Enum.reduce(entries, 0, fn {_, _, data, _}, acc -> acc + byte_size(data) end)

    %{
      count: length(entries),
      total_mb: Float.round(total_bytes / 1_048_576, 2),
      videos: videos
    }
  end

  def handle_call({:process, url, progress_callback}, _from, state) do
    result = do_process(url, progress_callback)
    {:reply, result, state}
  end

  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_token, _filename, _data, timestamp} ->
        now - timestamp > @ttl_ms
      end)

    Enum.each(expired, fn {token, filename, data, _} ->
      :ets.delete(@table, token)
      Logger.info("Expired video: #{filename} (#{Float.round(byte_size(data) / 1_048_576, 2)} MB)")
    end)

    if length(expired) > 0 do
      Logger.info("Cleaned up #{length(expired)} expired video(s)")
    end
  end

  defp do_process(url, progress_callback) do
    token = generate_token()
    work_dir = Path.join(@temp_dir, "chomp_#{token}")
    File.mkdir_p!(work_dir)

    try do
      progress_callback.("Fetching video info...")

      with {:ok, info} <- get_video_info(url),
           :ok <- check_limits(info),
           {:ok, video_path, filename} <- download_video(url, info, work_dir, progress_callback) do
        progress_callback.("Loading into memory...")
        data = File.read!(video_path)
        timestamp = System.monotonic_time(:millisecond)
        :ets.insert(@table, {token, filename, data, timestamp})
        {:ok, token}
      end
    rescue
      e ->
        Logger.error("Video processing failed: #{inspect(e)}")
        {:error, "Processing failed unexpectedly"}
    after
      File.rm_rf!(work_dir)
    end
  end

  defp check_limits(info) do
    filesize = info["filesize"] || info["filesize_approx"] || 0

    if filesize > @max_filesize_bytes do
      {:error, "Video too large (~#{format_size(filesize)}). Max is #{format_size(@max_filesize_bytes)}."}
    else
      :ok
    end
  end

  # Format filter: 720p max for landscape OR portrait videos
  @format_filter "bestvideo[height<=720]/bestvideo[width<=720]+bestaudio/best[height<=720]/best[width<=720]/best"

  defp get_video_info(url) do
    args = ["--dump-json", "--no-download", "--no-warnings", "-f", @format_filter, url]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {output, 0} ->
        json_start = String.trim(output) |> then(&Regex.run(~r/\{.*\}/s, &1))

        case json_start do
          [json] -> {:ok, Jason.decode!(json)}
          nil -> {:error, "No JSON in yt-dlp output"}
        end

      {error, _} ->
        {:error, "Failed to get video info: #{String.slice(error, 0, 200)}"}
    end
  rescue
    e -> {:error, "Failed to parse video info: #{inspect(e)}"}
  end

  defp download_video(url, info, work_dir, progress_callback) do
    progress_callback.("Downloading...")
    output_template = Path.join(work_dir, "video.%(ext)s")
    filename = build_filename(info)

    args = [
      "-f", @format_filter,
      "--merge-output-format", "mp4",
      "-o", output_template,
      "--no-playlist",
      url
    ]

    case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
      {_output, 0} ->
        case Path.wildcard(Path.join(work_dir, "video.*")) do
          [path] -> {:ok, path, filename}
          [] -> {:error, "Download completed but file not found"}
          _ -> {:error, "Multiple files found after download"}
        end

      {error, _} ->
        {:error, "Download failed: #{String.slice(error, 0, 200)}"}
    end
  end

  defp build_filename(info) do
    extractor = info["extractor"] || "video"
    id = info["id"] || info["display_id"] || "unknown"
    source = extractor |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    "#{source}-#{id}.mp4"
  end

  defp generate_token do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
