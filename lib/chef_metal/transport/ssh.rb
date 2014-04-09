require 'chef_metal/transport'
require 'uri'
require 'socket'

module ChefMetal
  class Transport
    class SSH < ChefMetal::Transport
      def initialize(host, username, ssh_options, options)
        require 'net/ssh'
        require 'net/scp'
        @host = host
        @username = username
        @ssh_options = ssh_options
        @options = options
      end

      attr_reader :host
      attr_reader :username
      attr_reader :ssh_options
      attr_reader :options

      def execute(command, execute_options = {})
        Chef::Log.info("Executing #{options[:prefix]}#{command} on #{username}@#{host}")
        stdout = ''
        stderr = ''
        exitstatus = nil
        channel = session.open_channel do |channel|
          # Enable PTY unless otherwise specified, some instances require this
          unless options[:ssh_pty_enable] == false
            channel.request_pty do |chan, success|
               raise "could not get pty" if !success && options[:ssh_pty_enable]
            end
          end


          channel.exec("#{options[:prefix]}#{command}") do |ch, success|
            raise "could not execute command: #{command.inspect}" unless success

            channel.on_data do |ch2, data|
              stdout << data
              stream_chunk(execute_options, data, nil)
            end

            channel.on_extended_data do |ch2, type, data|
              stderr << data
              stream_chunk(execute_options, nil, data)
            end

            channel.on_request "exit-status" do |ch, data|
              exitstatus = data.read_long
            end
          end
        end

        channel.wait

        Chef::Log.info("Completed #{command} on #{username}@#{host}: exit status #{exitstatus}")
        Chef::Log.debug("Stdout was:\n#{stdout}") if stdout != '' && !options[:stream] && !options[:stream_stdout]
        Chef::Log.info("Stderr was:\n#{stderr}") if stderr != '' && !options[:stream] && !options[:stream_stderr]
        SSHResult.new(command, execute_options, stdout, stderr, exitstatus)
      end

      def read_file(path)
        Chef::Log.debug("Reading file #{path} from #{username}@#{host}")
        result = StringIO.new
        download(path, result)
        result.string
      end

      def download_file(path, local_path)
        Chef::Log.debug("Downloading file #{path} from #{username}@#{host} to local #{local_path}")
        download(path, local_path)
      end

      def write_file(path, content)
        if options[:prefix]
          # Make a tempfile on the other side, upload to that, and sudo mv / chown / etc.
          remote_tempfile = "/tmp/#{File.basename(path)}.#{Random.rand(2**32)}"
          Chef::Log.debug("Writing #{content.length} bytes to #{remote_tempfile} on #{username}@#{host}")
          Net::SCP.new(session).upload!(StringIO.new(content), remote_tempfile)
          execute("mv #{remote_tempfile} #{path}")
        else
          Chef::Log.debug("Writing #{content.length} bytes to #{path} on #{username}@#{host}")
          Net::SCP.new(session).upload!(StringIO.new(content), path)
        end
      end

      def upload_file(local_path, path)
        if options[:prefix]
          # Make a tempfile on the other side, upload to that, and sudo mv / chown / etc.
          remote_tempfile = "/tmp/#{File.basename(path)}.#{Random.rand(2**32)}"
          Chef::Log.debug("Uploading #{local_path} to #{remote_tempfile} on #{username}@#{host}")
          Net::SCP.new(session).upload!(local_path, remote_tempfile)
          execute("mv #{remote_tempfile} #{path}")
        else
          Chef::Log.debug("Uploading #{local_path} to #{path} on #{username}@#{host}")
          Net::SCP.new(session).upload!(local_path, path)
        end
      end

      def make_url_available_to_remote(local_url)
        uri = URI(local_url)
        host = Socket.getaddrinfo(uri.host, uri.scheme, nil, :STREAM)[0][3]
        if host == '127.0.0.1' || host == '[::1]'
          # TODO IPv6
          Chef::Log.debug("Forwarding local server 127.0.0.1:#{uri.port} to port #{uri.port} on #{username}@#{host}")
          session.forward.remote(uri.port, "127.0.0.1", uri.port)
        end
        local_url
      end

      def disconnect
        if @session
          begin
            Chef::Log.debug("Closing SSH session on #{username}@#{host}")
            @session.close
          rescue
          end
          @session = nil
        end
      end

      def available?
        execute('pwd')
        true
      rescue Errno::ETIMEDOUT, Errno::ECONNREFUSED, Errno::ECONNRESET, Net::SSH::AuthenticationFailed, Net::SSH::Disconnect, Net::SSH::HostKeyMismatch
        Chef::Log.debug("#{username}@#{host} unavailable: could not execute 'pwd' on #{host}: #{$!.inspect}")
        false
      end

      protected

      def session
        @session ||= begin
          Chef::Log.debug("Opening SSH connection to #{username}@#{host} with options #{ssh_options.inspect}")
          Net::SSH.start(host, username, ssh_options)
        end
      end

      def download(path, local_path)
        channel = Net::SCP.new(session).download(path, local_path)
        begin
          channel.wait
        rescue Net::SCP::Error
          nil
        rescue
          # This works around https://github.com/net-ssh/net-scp/pull/10 until a new net-scp is merged.
          begin
            channel.close
            channel.wait
          rescue Net::SCP::Error
            nil
          end
        end
      end

      class SSHResult
        def initialize(command, options, stdout, stderr, exitstatus)
          @command = command
          @options = options
          @stdout = stdout
          @stderr = stderr
          @exitstatus = exitstatus
        end

        attr_reader :command
        attr_reader :options
        attr_reader :stdout
        attr_reader :stderr
        attr_reader :exitstatus

        def error!
          if exitstatus != 0
            # TODO stdout/stderr is already printed at info/debug level.  Let's not print it twice, it's a lot.
            msg = "Error: command '#{command}' exited with code #{exitstatus}.\n"
            raise msg
          end
        end
      end
    end
  end
end
