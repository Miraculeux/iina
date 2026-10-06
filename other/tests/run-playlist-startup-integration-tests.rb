require "socket"
require "fileutils"
require "tmpdir"

app = File.expand_path(ARGV.fetch(0) { abort "Usage: ruby #{__FILE__} /path/to/IINA.app (requires ffmpeg)" })
app = "#{app}/Contents/MacOS/IINA" if File.directory?(app)
abort "IINA executable not found: #{app}" unless File.executable?(app)
root = Dir.mktmpdir("iina-playlist-native-")
unless system("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=10",
              "-t", "30", "-pix_fmt", "yuv420p", "-c:v", "libx264", "#{root}/playlist-test.mp4")
  FileUtils.remove_entry(root)
  abort "Could not create the synthetic playback fixture"
end
fixture_dir = "#{root}/playlist-native-fixtures"
FileUtils.mkdir_p(fixture_dir)
server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
base = "http://127.0.0.1:#{port}"
video = File.binread("#{root}/playlist-test.mp4")
sockets = []
requests = []
server_thread = Thread.new do
  loop do
    socket = server.accept
    sockets << socket
    Thread.new(socket) do |client|
      begin
        request = client.gets
        next unless request
        path = request.split[1]
        requests << [path, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
        while (line = client.gets) && line != "\r\n"; end
        if path == "/hang"
          sleep 90
        else
          body = path == "/video.mp4" ? video : "not playable media\n"
          type = path == "/video.mp4" ? "video/mp4" : "text/plain"
          client.write("HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
          client.write(body)
        end
      rescue Errno::EPIPE, Errno::ECONNRESET
        # mpv cancels connections when skipping or stopping.
      ensure
        client.close unless client.closed?
      end
    end
  end
end

def check_case(app, fixture_dir, name, urls, extra, expected, duration = 25)
  path = "#{fixture_dir}/#{name}.m3u"
  File.write(path, "#EXTM3U\n" + urls.map.with_index { |url, i| "#EXTINF:-1,Entry #{i}\n#{url}\n" }.join)
  logs_root = File.expand_path("~/Library/Logs/com.colliderli.iina")
  previous_logs = Dir.glob("#{logs_root}/*/iina.log")
  args = [app, "-enableAdvancedSettings", "YES", "-enableLogging", "YES",
          "-recordPlaybackHistory", "NO", "-recordRecentFiles", "NO",
          "-pauseWhenOpen", "NO",
          "--mpv-mute=yes", "--mpv-resume-playback=no", "--mpv-save-position-on-quit=no",
          "--mpv-watch-later-directory=#{fixture_dir}/watch-later", "--mpv-ytdl=no"] + extra + [path]
  pid = Process.spawn(*args, out: "#{fixture_dir}/#{name}.stdout", err: [:child, :out])
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration
  log = ""
  log_path = nil
  begin
    loop do
      log_path ||= (Dir.glob("#{logs_root}/*/iina.log") - previous_logs).find { |candidate| File.read(candidate).include?(path) }
      log = File.read(log_path) if log_path && File.exist?(log_path)
      break if expected.all? { |text| log.include?(text) }
      raise "#{name}: timeout; log=#{log_path}\n#{log.lines.last(20).join}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.2
    end
    yield(log, log_path) if block_given?
    puts "PASS #{name}: #{expected.join('; ')}"
  ensure
    Process.kill("TERM", pid)
    Process.wait(pid)
  end
end

begin
  check_case(app, fixture_dir, "error-timeout-success",
             ["#{base}/bad", "#{base}/hang", "#{base}/video.mp4"], [],
             ["failed; trying another entry", "exceeded the 10-second", "Playback restarted"]) do |log, _|
    hanging = requests.find { |path, _| path == "/hang" }[1]
    successful = requests.find { |path, _| path == "/video.mp4" }[1]
    elapsed = successful - hanging
    raise "Timeout threshold not met: #{elapsed}" unless elapsed >= 9.9 && elapsed < 12
    raise "Skipped successful entry" if log.include?("M3U startup failed")
    puts "Measured timeout-to-next-request: #{elapsed.round(3)} seconds"
  end
  requests.clear
  check_case(app, fixture_dir, "resume-wrap",
             ["#{base}/video.mp4", "#{base}/bad", "#{base}/hang"], ["--mpv-playlist-start=2"],
             ["exceeded the 10-second", "Trying M3U startup entry at index 0", "Playback restarted"])
  requests.clear
  check_case(app, fixture_dir, "all-failed",
             ["#{base}/bad", "#{base}/hang"], ["--mpv-loop-playlist=inf"],
             ["M3U startup failed: no remaining playable entries"]) do |_, _|
    raise "Failed entries retried: #{requests}" unless requests.map(&:first).sort == ["/bad", "/hang"].sort
  end
  requests.clear
  check_case(app, fixture_dir, "all-errors",
             ["#{base}/bad", "#{base}/bad2"], ["--mpv-loop-playlist=inf"],
             ["M3U startup failed: no remaining playable entries"]) do |_, _|
    raise "Immediate failures retried: #{requests}" unless requests.map(&:first).sort == ["/bad", "/bad2"].sort
  end
  requests.clear
  check_case(app, fixture_dir, "keep-open-errors",
             ["#{base}/bad", "#{base}/video.mp4"], ["--mpv-keep-open=always"],
             ["failed; trying another entry", "Playback restarted"])
  requests.clear
  check_case(app, fixture_dir, "success-disables-fallback",
             ["#{base}/video.mp4", "#{base}/hang"], [],
             ["Playback restarted"]) do |_, log_path|
    sleep 11
    log = File.read(log_path)
    raise "Fallback survived success" if log.include?("exceeded the 10-second") || requests.any? { |path, _| path == "/hang" }
  end
  requests.clear
  check_case(app, fixture_dir, "paused-success-disables-fallback",
             ["#{base}/video.mp4", "#{base}/hang"], ["-pauseWhenOpen", "YES"],
             ["State changed from loaded to paused", "Playback restarted"]) do |_, log_path|
    sleep 11
    log = File.read(log_path)
    raise "Fallback skipped intentionally paused media" if log.include?("exceeded the 10-second") || requests.any? { |path, _| path == "/hang" }
  end
ensure
  server_thread.kill
  server_thread.join
  server.close
  sockets.each { |socket| socket.close unless socket.closed? }
  FileUtils.remove_entry(root)
end
