require "socket"
require "json"
require "fileutils"
require "tmpdir"

app = File.expand_path(ARGV.fetch(0) { abort "Usage: ruby #{__FILE__} /path/to/IINA.app (requires ffmpeg)" })
app = "#{app}/Contents/MacOS/IINA" if File.directory?(app)
abort "IINA executable not found: #{app}" unless File.executable?(app)
root = Dir.mktmpdir("iina-network-playback-", "/tmp")
server = nil
clients = []
workers = []
requests = Queue.new

def wait_for(message, timeout = 15)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    result = yield
    return result if result
    raise "Timeout: #{message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
end

def command(ipc_path, *args)
  UNIXSocket.open(ipc_path) do |socket|
    socket.puts(JSON.generate(command: args, request_id: 1))
    loop do
      raise "IPC response timed out: #{args}" unless IO.select([socket], nil, nil, 5)
      line = socket.gets
      raise "IPC connection closed: #{args}" unless line
      response = JSON.parse(line)
      next unless response["request_id"] == 1
      raise "IPC command failed: #{args}: #{response}" unless response["error"] == "success"
      return response["data"]
    end
  end
end

def run_case(app, root, name, path, extra = [])
  ipc_path = "#{root}/ipc.sock"
  logs_root = File.expand_path("~/Library/Logs/com.colliderli.iina")
  previous_logs = Dir.glob("#{logs_root}/*/iina.log")
  pid = Process.spawn(
    app, "-enableAdvancedSettings", "YES", "-enableLogging", "YES", "-logLevel", "0",
    "-useUserDefinedConfDir", "NO",
    "-userOptions", "((\"input-ipc-server\", \"#{ipc_path}\"))",
    "-recordPlaybackHistory", "NO", "-recordRecentFiles", "NO",
    "-resumeLastPosition", "NO", "-enableThumbnailPreview", "NO",
    "-enableLiveText", "NO", "-iinaEnablePluginSystem", "NO",
    "-enableControlBarAutoHide", "YES", "-controlBarAutoHideTimeout", "0.3",
    "-osdAutoHideTimeout", "0.3", "-prefetchPlaylistVideoDuration", "YES",
    "-pauseWhenOpen", "NO", "-fullScreenWhenOpen", "NO",
    "--mpv-mute=yes", "--mpv-ytdl=no", "--mpv-geometry=320x180+0+0",
    "--mpv-resume-playback=no", "--mpv-save-position-on-quit=no",
    "--mpv-watch-later-directory=#{root}/watch-later",
    *extra, path,
    out: "#{root}/#{name}.stdout", err: [:child, :out]
  )
  log_path = nil
  begin
    wait_for("#{name}: log and IPC socket") do
      log_path ||= (Dir.glob("#{logs_root}/*/iina.log") - previous_logs).find do |candidate|
        File.read(candidate).include?(path)
      end
      log_path && File.socket?(ipc_path)
    end
    read_log = -> { File.read(log_path) }
    wait_for("#{name}: playback ready") { read_log.call.include?("Playback restarted") }
    yield ipc_path, read_log
    puts "PASS #{name}"
  ensure
    if $!
      if log_path
        log = File.read(log_path)
        warn log.lines.grep(/ipc|SyncUITimer/).join
        warn log.lines.last(25).join
      end
      warn File.read("#{root}/#{name}.stdout").lines.last(15).join
    end
    Process.kill("TERM", pid)
    Process.wait(pid)
    FileUtils.remove_entry(File.dirname(log_path)) if log_path
  end
end

begin
  unless system("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=10",
                "-t", "60", "-pix_fmt", "yuv420p", "-c:v", "libx264",
                "-movflags", "+faststart", "#{root}/video.mp4")
    raise "Could not create synthetic playback fixture"
  end
  video = File.binread("#{root}/video.mp4")
  server = TCPServer.new("127.0.0.1", 0)
  base = "http://127.0.0.1:#{server.addr[1]}"
  server_thread = Thread.new do
    loop do
      client = server.accept
      clients << client
      workers << Thread.new(client) do |socket|
        begin
          request = socket.gets
          next unless request
          requests << request.split[1]
          while (line = socket.gets) && line != "\r\n"; end
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: #{video.bytesize}\r\nConnection: close\r\n\r\n")
          socket.write(video)
        rescue Errno::EPIPE, Errno::ECONNRESET
          # mpv may close the connection after probing or stopping.
        ensure
          socket.close unless socket.closed?
        end
      end
    end
  end

  playlist = "#{root}/network.m3u"
  File.write(playlist, "#EXTM3U\n#EXTINF:-1,Playing\n#{base}/playing.mp4\n" +
                       (1..8).map { |i| "#EXTINF:-1,Unused #{i}\n#{base}/unused-#{i}.mp4\n" }.join)
  run_case(app, root, "network-prefetch-and-music-mode", playlist,
           ["--music-mode", "-musicModeShowPlaylist", "YES"]) do |_, log|
    wait_for("Music Mode normal refresh") { log.call.match?(/SyncUITimer .*timeInterval 0\.1\b/) }
    sleep 3
    raise "Music Mode incorrectly throttles visible controls" if log.call.match?(/SyncUITimer .*timeInterval 1\.0\b/)
    paths = []
    paths << requests.pop until requests.empty?
    raise "Playlist prefetch opened unused network entries: #{paths}" if paths.any? { |path| path.include?("/unused-") }
    raise "Playback did not request the fixture" unless paths.include?("/playing.mp4")
    puts "Measured unused network-entry requests: 0"
  end

  [0, 2].each do |precision|
    run_case(app, root, "network-timer-precision-#{precision}", "#{base}/video.mp4",
             ["-timeDisplayPrecision", precision.to_s]) do |ipc, log|
      wait_for("hidden controls use 1-second timer") { log.call.match?(/SyncUITimer .*timeInterval 1\.0\b/) }
      offset = log.call.length
      command(ipc, "seek", 5, "absolute+exact")
      fast_interval = precision == 2 ? "0.04" : "0.1"
      wait_for("seek OSD restores #{fast_interval}-second timer") do
        log.call[offset..].include?("timeInterval #{fast_interval}")
      end
      wait_for("OSD hiding restores background timer") do
        log.call[offset..].match?(/SyncUITimer .*timeInterval 1\.0\b/)
      end
      offset = log.call.length
      command(ipc, "set_property", "pause", true)
      wait_for("pause stops timer") { log.call[offset..].include?("SyncUITimer didStop") }
      offset = log.call.length
      command(ipc, "set_property", "pause", false)
      wait_for("resume restores background timer") do
        log.call[offset..].match?(/SyncUITimer .*timeInterval 1\.0\b/)
      end
    end
  end

  run_case(app, root, "local-playback-idles", "#{root}/video.mp4") do |_, log|
    wait_for("local hidden controls stop timer") { log.call.include?("SyncUITimer didStop") }
    raise "Local playback incorrectly uses network background timer" if log.call.match?(/timeInterval 1\.0\b/)
  end
ensure
  server_thread&.kill
  server&.close
  clients.each { |client| client.close unless client.closed? }
  workers.each(&:join)
  FileUtils.remove_entry(root)
end
