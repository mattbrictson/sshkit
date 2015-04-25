require 'net/ssh'
require 'net/scp'

module Net
  module SSH
    class Config
      class << self
        def default_files
          @@default_files + [File.join(Dir.pwd, '.ssh/config')]
        end
      end
    end
  end
end

module SSHKit

  class Logger

    class Net::SSH::LogLevelShim
      attr_reader :output
      def initialize(output)
        @output = output
      end
      def debug(args)
        output << LogMessage.new(Logger::TRACE, args)
      end
      def error(args)
        output << LogMessage.new(Logger::ERROR, args)
      end
      def lwarn(args)
        output << LogMessage.new(Logger::WARN, args)
      end
    end

  end

  module Backend

    class Netssh < Abstract

      class Configuration
        attr_accessor :connection_timeout, :pty
        attr_writer :ssh_options

        def ssh_options
          @ssh_options || {}
        end
      end

      def capture(*args)
        # The behaviour to strip the full stdout was removed from the local backend in commit 7d15a9a,
        # but was left in for the net ssh backend.
        super(*args).strip
      end

      def upload!(local, remote, options = {})
        summarizer = transfer_summarizer('Uploading')
        with_ssh do |ssh|
          ssh.scp.upload!(local, remote, options, &summarizer)
        end
      end

      def download!(remote, local=nil, options = {})
        summarizer = transfer_summarizer('Downloading')
        with_ssh do |ssh|
          ssh.scp.download!(remote, local, options, &summarizer)
        end
      end

      @pool = SSHKit::Backend::ConnectionPool.new

      class << self
        attr_accessor :pool

        def configure
          yield config
        end

        def config
          @config ||= Configuration.new
        end
      end

      private

      def transfer_summarizer(action)
        last_name = nil
        last_percentage = nil
        proc do |ch, name, transferred, total|
          percentage = (transferred.to_f * 100 / total.to_f)
          unless percentage.nan?
            message = "#{action} #{name} #{percentage.round(2)}%"
            percentage_r = (percentage / 10).truncate * 10
            if percentage_r > 0 && (last_name != name || last_percentage != percentage_r)
              info message
              last_name = name
              last_percentage = percentage_r
            else
              debug message
            end
          else
            warn "Error calculating percentage #{transferred}/#{total}, " <<
              "is #{name} empty?"
          end
        end
      end

      def execute_command(cmd)
          output << cmd
          cmd.started = true
          exit_status = nil
          with_ssh do |ssh|
            ssh.open_channel do |chan|
              chan.request_pty if Netssh.config.pty
              chan.exec cmd.to_command do |ch, success|
                chan.on_data do |ch, data|
                  cmd.stdout = data
                  cmd.full_stdout += data
                  output << cmd
                end
                chan.on_extended_data do |ch, type, data|
                  cmd.stderr = data
                  cmd.full_stderr += data
                  output << cmd
                end
                chan.on_request("exit-status") do |ch, data|
                  exit_status = data.read_long
                end
                #chan.on_request("exit-signal") do |ch, data|
                #  # TODO: This gets called if the program is killed by a signal
                #  # might also be a worthwhile thing to report
                #  exit_signal = data.read_string.to_i
                #  warn ">>> " + exit_signal.inspect
                #  output << cmd
                #end
                chan.on_open_failed do |ch|
                  # TODO: What do do here?
                  # I think we should raise something
                end
                chan.on_process do |ch|
                  # TODO: I don't know if this is useful
                end
                chan.on_eof do |ch|
                  # TODO: chan sends EOF before the exit status has been
                  # writtend
                end
              end
              chan.wait
            end
            ssh.loop
          end
          # Set exit_status and log the result upon completion
          if exit_status
            cmd.exit_status = exit_status
            output << cmd
          end
      end

      def with_ssh
        host.ssh_options = Netssh.config.ssh_options.merge(host.ssh_options || {})
        conn = self.class.pool.checkout(
          String(host.hostname),
          host.username,
          host.netssh_options,
          &Net::SSH.method(:start)
        )
        begin
          yield conn.connection
        ensure
          self.class.pool.checkin conn
        end
      end

    end
  end

end
