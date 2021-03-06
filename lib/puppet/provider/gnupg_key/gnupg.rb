require 'etc'
require 'tmpdir'
require 'puppet/file_serving/content'

Puppet::Type.type(:gnupg_key).provide(:gnupg) do

  @doc = 'Provider for gnupg_key type.'

  defaultfor :kernel => 'Linux'
  confine :kernel => 'Linux'

  def self.instances
    []
  end

  # although we do not use the commands class it's used to detect if the gpg and awk commands are installed on the system
  commands :gpg => 'gpg'
  commands :awk => 'awk'

  def remove_key
    if resource[:key_type] == :public
      command = "gpg --batch --yes --delete-key #{fingerprint}"
    elsif resource[:key_type] == :private
      command = "gpg --batch --yes --delete-secret-key #{fingerprint}"
    elsif resource[:key_type] == :both
      command = "gpg --batch --yes --delete-secret-and-public-key #{fingerprint}"
    end
    run_gpg_command(command)
  end

  # where most of the magic happens
  # TODO implement dry-run to check if the key_id match the content of the file
  def add_key
    if resource[:key_server]
      add_key_from_key_server
    elsif resource[:key_source]
      add_key_from_key_source
    elsif resource[:key_content]
      add_key_from_key_content
    end
    create_trustdb
  end

  def fingerprint
    command = "gpg --fingerprint --with-colons #{resource[:key_id]} | awk -F: '$1 == \"fpr\" {print $10;}'"
    run_gpg_command(command)
  end

  def add_key_from_key_server
    command = "gpg --keyserver #{resource[:key_server]} --recv-keys #{resource[:key_id]}"
    run_gpg_command(command)
  end

  def add_key_from_key_source
    if Puppet::Util.absolute_path?(resource[:key_source])
      add_key_at_path
    else
      add_key_at_url
    end
  end

  def add_key_from_key_content
    path = create_temporary_file(user_id, resource[:key_content])
    command = "gpg --import #{path}"
    run_gpg_command(command)
  end

  def add_key_at_path
    if File.file?(resource[:key_source])
      command = "gpg --import #{resource[:key_source]}"
      run_gpg_command(command)
    elsif
      raise Puppet::Error, "Local file #{resource[:key_source]} for #{resource[:key_id]} does not exist"
    end
  end

  def add_key_at_url
    uri = URI.parse(URI.escape(resource[:key_source]))
    case uri.scheme
    when /https/
      command = "wget -O- #{resource[:key_source]} | gpg --import"
    when /http/
      command = "gpg --fetch-keys #{resource[:key_source]}"
    when 'puppet'
      path = create_temporary_file user_id, puppet_content
      command = "gpg --import #{path}"
    end
    run_gpg_command(command)
  end

  def user_id
    begin
      Etc.getpwnam(resource[:user]).uid
    rescue => e
      raise Puppet::Error, "User #{resource[:user]} does not exists"
    end
  end

  def create_temporary_file user_id, content
    Puppet::Util::SUIDManager.asuser(user_id) do
      tmpfile = Tempfile.open(['golja-gnupg', 'key'])
      tmpfile.write(content)
      tmpfile.flush
      break tmpfile.path.to_s
    end
  end

  def puppet_content
    # Look up (if necessary) and return remote content.
    return @content if @content
    unless tmp = Puppet::FileServing::Content.indirection.find(resource[:key_source], :environment => resource.catalog.environment, :links => :follow)
      fail "Could not find any content at %s" % resource[:key_source]
    end
    @content = tmp.content
  end

  def create_trustdb
    ownertrust = fingerprint.delete("\n") + ":#{resource[:trust_level]}:\n"
    path = create_temporary_file(user_id, ownertrust)

    command = "gpg --import-ownertrust #{path}"
    run_gpg_command(command)
  end

  def exists?
    # public and both can be grouped since private can't be present without public,
    # both only applies to delete and delete still has something to do if only
    # one of the keys is present
    if resource[:key_type] == :public || resource[:key_type] == :both
      command = "gpg --list-keys --with-colons #{resource[:key_id]}"
    elsif resource[:key_type] == :private
      command = "gpg --list-secret-keys --with-colons #{resource[:key_id]}"
    end

    output = Puppet::Util::Execution.execute(command, :uid => user_id)
    if output.exitstatus == 0
      return true
    elsif output.exitstatus == 2
      return false
    else
      raise Puppet::Error, "Non recognized exit status from GnuPG #{output.exitstatus} #{output}"
    end
  end

  def create
    add_key
  end

  def destroy
    remove_key
  end

  def run_gpg_command command
    begin
      Puppet::Util::Execution.execute(command, :uid => user_id, :failonfail => true, :combine => true)
    rescue Puppet::ExecutionFailure => e
      raise Puppet::Error, "Error while executing command: #{command}\nError: #{e.inspect}"
    end
  end

end
