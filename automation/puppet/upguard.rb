require 'puppet'
require 'json'
require 'erb'

Puppet::Reports.register_report(:upguard) do

  VERSION = "v1.5.0"
  VERSION_TAG = "Added by #{File.basename(__FILE__)} #{VERSION}"
  desc "Create a node (if not present) and kick off a node scan in UpGuard if changes were made."

  configfile = File.join([File.dirname(Puppet.settings[:config]), "upguard.yaml"])
  raise(Puppet::ParseError, "upguard.yaml config file #{configfile} not readable") unless File.exist?(configfile)
  begin
    config = YAML.load_file(configfile)
  rescue TypeError => e
    raise(Puppet::ParserError, "upguard.yaml file is invalid")
  end

  APPLIANCE_URL            = config[:appliance_url]
  PUPPETDB_URL             = config[:puppetdb_url]
  COMPILE_MASTER_PEM       = config[:compile_master_pem]
  SERVICE_KEY              = config[:service_key]
  SECRET_KEY               = config[:secret_key]
  API_KEY                  = "#{SERVICE_KEY}#{SECRET_KEY}"
  CM                       = config[:sites]
  ENVIRONMENT              = config[:environment]
  TEST_OS                  = config[:test_os]
  TEST_NODE_NAME           = config[:test_node_name]
  TEST_LINUX_HOSTNAME      = config[:test_linux_hostname]
  TEST_WINDOWS_HOSTNAME    = config[:test_windows_hostname]
  UNKNOWN_OS_NODE_GROUP_ID = config[:unknown_os_node_group_id]
  SLEEP_BEFORE_SCAN        = config[:sleep_before_scan]
  IGNORE_HOSTNAME_INCLUDE  = config[:ignore_hostname_include]
  OFFLINE_MODE_FILENAME    = config[:offline_mode_filename]

  def process
    Puppet.info("#{log_prefix} starting report processor #{VERSION}")

    Puppet.info("#{log_prefix} APPLIANCE_URL=#{APPLIANCE_URL}")
    Puppet.info("#{log_prefix} PUPPETDB_URL=#{PUPPETDB_URL}")
    Puppet.info("#{log_prefix} COMPILE_MASTER_PEM=#{COMPILE_MASTER_PEM}")
    # Commenting out as these log lines contain sensitive information.
    # Puppet.info("#{log_prefix} SERVICE_KEY=#{SERVICE_KEY}")
    # Puppet.info("#{log_prefix} SECRET_KEY=#{SECRET_KEY}")
    # Puppet.info("#{log_prefix} API_KEY=#{API_KEY}")
    # Puppet.info("#{log_prefix} CM=#{CM}")
    Puppet.info("#{log_prefix} ENVIRONMENT=#{ENVIRONMENT}")
    Puppet.info("#{log_prefix} TEST_OS=#{TEST_OS}")
    Puppet.info("#{log_prefix} TEST_NODE_NAME=#{TEST_NODE_NAME}")
    Puppet.info("#{log_prefix} TEST_LINUX_HOSTNAME=#{TEST_LINUX_HOSTNAME}")
    Puppet.info("#{log_prefix} TEST_WINDOWS_HOSTNAME=#{TEST_WINDOWS_HOSTNAME}")
    Puppet.info("#{log_prefix} UNKNOWN_OS_NODE_GROUP_ID=#{UNKNOWN_OS_NODE_GROUP_ID}")
    Puppet.info("#{log_prefix} SLEEP_BEFORE_SCAN=#{SLEEP_BEFORE_SCAN}")
    Puppet.info("#{log_prefix} IGNORE_HOSTNAME_INCLUDE=#{IGNORE_HOSTNAME_INCLUDE}")
    Puppet.info("#{log_prefix} OFFLINE_MODE_FILENAME=#{OFFLINE_MODE_FILENAME}")

    self.status != nil ? status = self.status : status = 'undefined'
    Puppet.info("#{log_prefix} status=#{status}")

    if test_env
      # Unchanged here so that you can run `puppet-agent -t` over and over.
      run_states = %w(unchanged)
    else
      run_states = %w(changed failed)
    end

    # For most scenarios, make sure the node is added to upguard and is being scanned.
    unless run_states.include?(status)
      Puppet.info("#{log_prefix} returning early, '#{status}' not in run_states")
      return
    end

    ##########################################################################
    # PUPPET DB (PDB) METHODS                                                #
    ##########################################################################

    # Create a hash to store the PDB info we need.
    puppet_run = {}

    # Get the node name
    puppet_run['node_ip_hostname'] = pdb_get_hostname(self.host)
    if !IGNORE_HOSTNAME_INCLUDE.nil? && puppet_run['node_ip_hostname'].include?(IGNORE_HOSTNAME_INCLUDE)
      Puppet.info("#{log_prefix} returning early, '#{puppet_run['node_ip_hostname']}' includes '#{IGNORE_HOSTNAME_INCLUDE}'")
      return
    end

    # We use this to tag node scans with the puppet "file(s)" that have caused the change
    puppet_run['manifest_filename'] = pdb_manifest_files(self.logs)
    # Used to set the node OS type in UpGuard
    puppet_run['os'] = pdb_get_os(puppet_run['node_ip_hostname'])
    Puppet.info("#{log_prefix} status=#{status} os=#{puppet_run['os']}")
    # Get trusted facts from Puppet (once)
    trusted_facts = pdb_get_trusted_facts(puppet_run['node_ip_hostname'])
    # Extract the role, environment and datacenter
    puppet_run['node_group_name'] = pdb_get_role(trusted_facts)
    puppet_run['environment_name'] = pdb_get_environment(trusted_facts)
    puppet_run['datacenter_name'] = pdb_get_datacenter(trusted_facts)
    # The format for environment names is datacenter_environment
    puppet_run['environment_name'] = generate_environment_name(puppet_run['datacenter_name'], puppet_run['environment_name'])

    ##########################################################################
    # DRIVER METHODS                                                         #
    ##########################################################################

    # Check to see if we need to operate in offline mode as UpGuard may not always we available.
    if upguard_offline
      Puppet.info("#{log_prefix} ########################################")
      Puppet.info("#{log_prefix} #       OPERATING IN OFFLINE MODE      #")
      Puppet.info("#{log_prefix} ########################################")
      # Let the user know that this scan was done from offline mode.
      puppet_run['manifest_filename'] += ERB::Util.url_encode(" (upguard.rb offline mode)")
      store_puppet_run(OFFLINE_MODE_FILENAME, puppet_run)
      Puppet.info("#{log_prefix} returning early, '#{APPLIANCE_URL}' is offline")
      return
    else
      if File.exists?(OFFLINE_MODE_FILENAME)
        # We're back online, but have a backlog of nodes to process.
        Puppet.info("#{log_prefix} #{OFFLINE_MODE_FILENAME} present, working through puppet runs backlog")
        file_state = File.read(OFFLINE_MODE_FILENAME)
        puppet_runs = JSON.parse(file_state)
        if !puppet_runs.nil? && puppet_runs.any?
          unique_puppet_runs = puppet_runs.uniq {|r| r['node_ip_hostname']}
          unique_puppet_runs.each do |run|
            provision_node_in_upguard(run)
          end
        else
          Puppet.info("#{log_prefix} #{OFFLINE_MODE_FILENAME} present, but an array of puppet runs not found, removing")
        end
        # Finally, remove the state file
        FileUtils.rm(OFFLINE_MODE_FILENAME)
      else
        # UpGuard not offline, no state file present, just a usual run.
        provision_node_in_upguard(puppet_run)
      end
    end
  end

  ##############################################################################
  # DRIVER METHODS                                                             #
  ##############################################################################

  def provision_node_in_upguard(puppet_run)
    # Get node group id from UpGuard
    node_group_id = lookup_or_create_node_group(puppet_run['node_group_name'], nil)
    os_node_group_id = -1
    if puppet_run['os'] == 'CentOS'
      os_node_group_id = lookup_or_create_node_group('Linux_Static', nil)
    elsif puppet_run['os'] == 'windows'
      os_node_group_id = lookup_or_create_node_group('Windows_Static', nil)
    end
    # Get environment id from UpGuard
    environment_id = lookup_or_create_environment(puppet_run['environment_name'])
    # Determine if we can find the node or if we need to create it
    node = lookup_or_create_node(puppet_run['node_ip_hostname'], puppet_run['os'], puppet_run['datacenter_name'])
    # Make sure to add the node to the node group
    add_node_to_group(node[:id], node_group_id)
    if os_node_group_id != -1
      add_node_to_group(node[:id], os_node_group_id)
    end
    # Make sure to add the node to the environment
    add_node_to_environment(node[:id], environment_id)
    # For new nodes, sleep to let Puppet catch up
    if node[:created]
      Puppet.info("#{log_prefix} new node, sleeping for #{SLEEP_BEFORE_SCAN} seconds...")
      sleep SLEEP_BEFORE_SCAN
      # Kick off a vuln scan only for newly created nodes
      #vuln_scan(node[:id], node_ip_hostname)
    end
    node_scan(node[:id], puppet_run['node_ip_hostname'], puppet_run['manifest_filename'])
  end

  def store_puppet_run(offline_mode_filename, puppet_run)
    # Take all the info about the node from PDB and store it to file.
    Puppet.info("#{log_prefix} puppet_run: #{puppet_run}")
    if File.exists?(offline_mode_filename)
      # Read in existing state file.
      Puppet.info("#{log_prefix} state file already exists, reading in contents")
      file_state = File.read(offline_mode_filename)
      puppet_runs = JSON.parse(file_state)
      puppet_runs << puppet_run
    else
      Puppet.info("#{log_prefix} state file not present, creating one now")
      puppet_runs = []
    end
    puppet_runs << puppet_run
    # Write the array back to the state file
    Puppet.info("#{log_prefix} added '#{puppet_run['node_ip_hostname']}' to the state file to process when upguard is back online")
    File.write(offline_mode_filename, JSON.pretty_generate(puppet_runs))
  end

  def upguard_offline
    offline_status = true
    # Perform an authenticated request to UpGuard. This additionally proves that ones auth credentials are correct.
    response = `curl -X GET -s -m 20 -H 'Authorization: Token token="#{API_KEY}"' -H 'Accept: application/json' -H 'Content-Type: application/json' #{APPLIANCE_URL}/api/v2/users`
    Puppet.info("#{log_prefix} user_lookup response=#{response}")
    if !response.nil? && response.include?("email")
      offline_status = false
    end
    offline_status
  end

  def generate_environment_name(datacenter_name, environment_name)
    if (!datacenter_name.nil? && !datacenter_name.empty?) && (!environment_name.nil? && !environment_name.empty?)
      datacenter_environment_name = "#{datacenter_name}_#{environment_name}"
      Puppet.err("#{log_prefix} datacenter_environment_name=#{datacenter_environment_name}")
      datacenter_environment_name
    else
      Puppet.err("#{log_prefix} either pp_datacenter (#{datacenter_name}) or pp_environment (#{environment_name}) is nil or empty")
      "tf_problem"
    end
  end

  def lookup_or_create_node_group(node_group_name, node_group_rule)
    if !node_group_name.nil? && !node_group_name.empty?
      # Create the node_group in UpGuard. If it already exists, and error will be returned - just ignore it.
      node_group_id = upguard_node_group_create(API_KEY, APPLIANCE_URL, node_group_name, node_group_rule)
      Puppet.info("#{log_prefix} node group found/created: node_group_id=#{node_group_id}")
      node_group_id
    else
      Puppet.err("#{log_prefix} node group name nil or empty, skipping lookup/creation")
      nil
    end
  end

  def lookup_or_create_environment(environment_name)
    if !environment_name.nil? && !environment_name.empty?
      # Create the environment in UpGuard. If it already exists, and error will be returned - just ignore it.
      environment_id = upguard_environment_create(API_KEY, APPLIANCE_URL, environment_name)
      Puppet.info("#{log_prefix} environment found/created: environment_id=#{environment_id}")
      environment_id
    else
      Puppet.err("#{log_prefix} environment name nil or empty, skipping lookup/creation")
      nil
    end
  end

  def lookup_or_create_node(node_ip_hostname, os, datacenter_name)
    node = {}
    lookup = upguard_node_lookup(API_KEY, APPLIANCE_URL, node_ip_hostname)
    if !lookup.nil? && !lookup["node_id"].nil?
      node[:id] = lookup["node_id"]
      node[:created] = false
      Puppet.info("#{log_prefix} node already exists: node[:id]=#{node[:id]}")
      node
    elsif !lookup.nil? && !lookup["error"].nil? && (lookup["error"] == "Not Found")
      node[:id] = upguard_node_create(API_KEY, APPLIANCE_URL, node_ip_hostname, os, datacenter_name)
      node[:created] = true
      Puppet.info("#{log_prefix} node not found so created: node[:id]=#{node[:id]}")
      node
    else
      Puppet.err("#{log_prefix} failed to lookup node: #{lookup}")
      raise StandardError, "#{log_prefix} unable to get a node id: confirm config variables are correct and upguard appliance is reachable"
    end
  end

  def add_node_to_group(node_id, node_group_id)
    if !node_group_id.nil? && !node_group_id.to_s.include?("error")
      add_to_node_group_response = upguard_add_to_node_group(API_KEY, APPLIANCE_URL, node_id, node_group_id)
      if !add_to_node_group_response.nil? && add_to_node_group_response.to_s.include?("Node is already in the group")
        Puppet.info("#{log_prefix} node is already in the node group")
      else
        Puppet.info("#{log_prefix} added the node to the node group")
      end
    else
      Puppet.err("#{log_prefix} obtaining node_group_id failed: #{node_group_id}")
    end
  end

  def add_node_to_environment(node_id, environment_id)
    if !environment_id.nil? && !environment_id.to_s.include?("error")
      add_to_environment_response = upguard_add_to_environment(API_KEY, APPLIANCE_URL, node_id, environment_id)
      if !add_to_environment_response.nil? && add_to_environment_response.to_s.include?("error")
        Puppet.info("#{log_prefix} node environment_id could not be updated")
      else
        Puppet.info("#{log_prefix} node environment_id updated")
      end
    else
      Puppet.err("#{log_prefix} obtaining environment_id failed: #{environment_id}")
    end
  end

  def node_scan(node_id, node_ip_hostname, manifest_filename)
    job = upguard_node_scan(API_KEY, APPLIANCE_URL, node_id, manifest_filename)
    if job["job_id"]
      Puppet.info("#{log_prefix} node scan kicked off against #{node_ip_hostname} (#{APPLIANCE_URL}/jobs/#{job["job_id"]}/show_job?show_all=true)")
    else
      Puppet.err("#{log_prefix} failed to kick off node scan against #{node_ip_hostname} (#{node_id}): #{job}")
    end
  end

  def vuln_scan(node_id, node_ip_hostname)
    vuln_job = upguard_node_vuln_scan(API_KEY, APPLIANCE_URL, node_id)
    if vuln_job["job_id"]
      Puppet.info("#{log_prefix} node vulnerability scan kicked off against #{node_ip_hostname} (#{APPLIANCE_URL}/jobs/#{vuln_job["job_id"]}/show_job?show_all=true)")
    else
      Puppet.err("#{log_prefix} failed to kick off node vulnerability scan against #{node_ip_hostname} (#{node_id}): #{vuln_job}")
    end
  end

  #############################################################################
  # HELPER METHODS                                                            #
  #############################################################################

  # Used for debugging (shortcuts needing to use PDB).
  def test_env
    if ENVIRONMENT.is_a?(String) && ENVIRONMENT == "test"
      true
    else
      false
    end
  end

  # Format logs in a consistent, easily grep-able way.
  def log_prefix
    if self.host
      "upguard #{self.host}:"
    else
      "upguard:"
    end
  end

  # Determine the correct UpGuard connection manager to scan the node with.
  def determine_domain_details(node_name, node_os, datacenter_name)
    default_cmg_details = {}
    default_cmg_details['id'] = 1
    default_cmg_details['service_account'] = ""
    default_cmg_details['service_password'] = ""

    # Return the default connection manager group if a node name or node os isn't provided
    if node_name.nil? || node_os.nil?
      Puppet.info("#{log_prefix} node name or node os not provided, using default connection manager group")
      return default_cmg_details
    end
    # Downcase once here for further work
    node_name = node_name.downcase
    node_os   = node_os.downcase

    if CM.is_a?(Array) && CM.any?
      CM.each do |site|
        site_name = site['name']
        next if site_name.nil?
        next unless site_name == datacenter_name
        domains = site['domains']

        if domains.is_a?(Array) && domains.any?
          domains.each do |domain|
            # Skip element if it's not formatted correctly
            domain_name = domain['name']
            next if domain_name.nil?
            next unless node_name.end_with?(domain_name)

            if node_os == 'windows'
              windows_cmgs = domain['windows_connection_manager_groups']
              # Check that we have a Windows connection manager group for the given domain
              if windows_cmgs.is_a?(Array) && windows_cmgs.any?
                # Make sure the domain has a node group created for it (this helps with creating variable overrides)
                # The node group rule here will automatically add the node to the node group (and other others)
                lookup_or_create_node_group(domain_name, ".+#{domain_name}$")
                # Multiple (Windows) connection manager groups can be defined for a domain.
                # Currently, we just use the first.
                return windows_cmgs[0]
              end
            else
              ssh_cmgs = domain['ssh_connection_manager_groups']
              if ssh_cmgs.is_a?(Array) && ssh_cmgs.any?
                # Make sure the domain has a node group created for it (this helps with creating variable overrides)
                lookup_or_create_node_group(domain_name, ".+#{domain_name}$")
                return ssh_cmgs[0]
              end
            end
          end
        end
      end

      # If we got here then we have a node with a domain that isn't mapped to a connection manager group
      Puppet.info("#{log_prefix} #{node_name} could not be mapped to a connection manager group, using default connection manager group instead")
      return default_cmg_details
    end
  end

  #############################################################################
  # PUPPET DB (PDB) METHODS                                                   #
  #############################################################################

  # Hostname is a variable we can source from "self".
  def pdb_get_hostname(node_ip_hostname)
    if test_env
      node_ip_hostname = TEST_NODE_NAME
      Puppet.info("#{log_prefix} node_ip_hostname=#{node_ip_hostname}")
      node_ip_hostname
    else
      Puppet.info("#{log_prefix} node_ip_hostname=#{node_ip_hostname}")
      node_ip_hostname
    end
  end

  # Get trusted facts from Puppet.
  def pdb_get_trusted_facts(node_ip_hostname)
    if test_env
      trusted_facts = '[{"certname":"host-name-01.domain.com","name":"trusted","value":{"authenticated":"remote","certname":"host-name-01.domain.com","domain":"domain.com","extensions":{"company_trusted_swimlane":"n/a","pp_datacenter":"mtv","pp_environment":"qa","pp_product":"test","pp_role":"rabbit_mq"},"hostname":"host-name-01"},"environment":"tier2"}]'
      trusted_facts = JSON.load(trusted_facts)
      return trusted_facts
    end

    response = `curl -X GET #{PUPPETDB_URL}/pdb/query/v4/nodes/#{node_ip_hostname}/facts -d 'query=["in", ["name","certname"], ["extract", ["name","certname"], ["select_fact_contents", ["and", ["=", "path", ["trusted", "authenticated"]], ["=","value","remote"]]]]]' --tlsv1 --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem --cert /etc/puppetlabs/puppet/ssl/certs/#{COMPILE_MASTER_PEM} --key /etc/puppetlabs/puppet/ssl/private_keys/#{COMPILE_MASTER_PEM}`
    Puppet.info("#{log_prefix} trusted facts for #{node_ip_hostname} is: response=#{response}")
    trusted_facts = JSON.load(response)
    trusted_facts
  end

  # Extract out the role (which we eventually map to an UpGuard node group).
  def pdb_get_role(trusted_facts)
    if trusted_facts && trusted_facts[0] && trusted_facts[0]['value'] && trusted_facts[0]['value']['extensions'] && trusted_facts[0]['value']['extensions']['pp_role']
      role = trusted_facts[0]['value']['extensions']['pp_role']
      Puppet.info("#{log_prefix} puppet role for node is: role=#{role}")
      role
    else
      nil
    end
  end

  # Extract out the environment (which we eventually map to an UpGuard environment).
  def pdb_get_environment(trusted_facts)
    if trusted_facts && trusted_facts[0] && trusted_facts[0]['value'] && trusted_facts[0]['value']['extensions'] && trusted_facts[0]['value']['extensions']['pp_environment']
      environment = trusted_facts[0]['value']['extensions']['pp_environment']
      Puppet.info("#{log_prefix} puppet environment for node is: environment=#{environment}")
      environment
    else
      nil
    end
  end

  # Extract out the datacenter (which we eventually map to an UpGuard node group).
  def pdb_get_datacenter(trusted_facts)
    if trusted_facts && trusted_facts[0] && trusted_facts[0]['value'] && trusted_facts[0]['value']['extensions'] && trusted_facts[0]['value']['extensions']['pp_datacenter']
      datacenter = trusted_facts[0]['value']['extensions']['pp_datacenter']
      Puppet.info("#{log_prefix} puppet datacenter for node is: datacenter=#{datacenter}")
      datacenter
    else
      nil
    end
  end

  # Get the node OS. This isn't something that trusted facts can tell us.
  def pdb_get_os(hostname)
    if test_env
      os = TEST_OS
      Puppet.info("#{log_prefix} os: #{os}")
      return os
    end

    response = `curl -X GET #{PUPPETDB_URL}/pdb/query/v4/facts/operatingsystem --data-urlencode 'query=["=", "certname", "#{hostname}"]' --tlsv1 --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem --cert /etc/puppetlabs/puppet/ssl/certs/#{COMPILE_MASTER_PEM} --key /etc/puppetlabs/puppet/ssl/private_keys/#{COMPILE_MASTER_PEM}`
    Puppet.info("#{log_prefix} get_os: response=#{response}")
    os_details = JSON.load(response)
    if os_details && os_details[0]
      os = os_details[0]['value']
      Puppet.info("#{log_prefix} os: #{os}")
      os
    else
      "unknown"
    end
  end

  # Work out what Puppet files made the "change". We use this to tag the node scan in UpGuard.
  def pdb_manifest_files(logs)
    if test_env
      manifest_filename = "test node scan"
      manifest_filename = ERB::Util.url_encode(manifest_filename)
      Puppet.info("#{log_prefix} manifest_filename=#{manifest_filename}")
      return manifest_filename
    end

    manifest_filename = []
    default = ERB::Util.url_encode("puppet run")

    if logs && logs.any?
      (logs).each do |log|
        Puppet.info("#{log_prefix} log: #{log}")
        if log.file
          Puppet.info("#{log_prefix} log.file: #{log.file}")
          segments = log.file.split("/")
          if segments && segments.any?
            manifest_filename.push(segments.last)
          end
        end
      end
    else
      manifest_filename.push("#{default}")
    end
    if manifest_filename && manifest_filename.any?
      manifest_filename = manifest_filename.uniq.sort
      manifest_filename = ERB::Util.url_encode(manifest_filename.join(", ").slice(0..40))
    else
      manifest_filename = "#{default}"
    end

    Puppet.info("#{log_prefix} manifest_filename=#{manifest_filename}")
    manifest_filename
  end

  #############################################################################
  # UPGUARD METHODS                                                           #
  #############################################################################

  # Add the node to the node group.
  def upguard_add_to_node_group(api_key, instance, node_id, node_group_id)
    Puppet.info("#{log_prefix} adding node_id=#{node_id} to node_group_id=#{node_group_id}")
    response = `curl -X POST -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' #{instance}/api/v2/node_groups/#{node_group_id}/add_node.json?node_id=#{node_id}`
    Puppet.info("#{log_prefix} add_to_node_group response=#{response}")
    JSON.load(response)
  end
  module_function :upguard_add_to_node_group

  # Add the node to the environment. We do this by updating the node rather than using an add_node endpoint.
  def upguard_add_to_environment(api_key, instance, node_id, environment_id)
    Puppet.info("#{log_prefix} adding node_id=#{node_id} to environment_id=#{environment_id}")
    response = `curl -X PUT -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{ "node": { "environment_id": "#{environment_id}", "description": "#{VERSION_TAG}" }}' #{instance}/api/v2/nodes/#{node_id}`
    Puppet.info("#{log_prefix} add_to_environment response=#{response}")
  end
  module_function :upguard_add_to_environment

  # Check to see if the node has already been added to UpGuard. If so, return it's node_id.
  def upguard_node_lookup(api_key, instance, external_id)
    response = `curl -X GET -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' #{instance}/api/v2/nodes/lookup.json?external_id=#{external_id}`
    Puppet.info("#{log_prefix} node_lookup response=#{response}")
    JSON.load(response)
  end
  module_function :upguard_node_lookup

  # We create UpGuard node groups to map to Puppet roles
  def upguard_node_group_create(api_key, instance, node_group_name, node_group_rule)
    create_response = `curl -X POST -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{ "node_group": { "name": "#{node_group_name}", "description": "#{VERSION_TAG}", "node_rules": "#{node_group_rule}" }}' #{instance}/api/v2/node_groups`
    Puppet.info("#{log_prefix} node_group_create response=#{create_response}")
    lookup_response = `curl -X GET -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' #{instance}/api/v2/node_groups/lookup.json?name=#{node_group_name}`
    Puppet.info("#{log_prefix} node_group_lookup response=#{lookup_response}")
    lookup_json = JSON.load(lookup_response)
    if lookup_json && lookup_json['node_group_id']
      lookup_json['node_group_id']
    else
      nil
    end
  end
  module_function :upguard_node_group_create

  # We create UpGuard environments to map to Puppet environments
  def upguard_environment_create(api_key, instance, environment_name)
    create_response = `curl -X POST -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{ "environment": { "name": "#{environment_name}", "short_description": "#{VERSION_TAG}" }}' #{instance}/api/v2/environments`
    Puppet.info("#{log_prefix} environment_create response=#{create_response}")
    lookup_response = `curl -X GET -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' #{instance}/api/v2/environments/lookup.json?name=#{environment_name}`
    Puppet.info("#{log_prefix} environment_lookup response=#{lookup_response}")
    lookup_json = JSON.load(lookup_response)
    if lookup_json && lookup_json['environment_id']
      lookup_json['environment_id']
    else
      nil
    end
  end
  module_function :upguard_environment_create

  # Creates the node in UpGuard
  def upguard_node_create(api_key, instance, ip_hostname, os, datacenter_name)
    domain_details = determine_domain_details(ip_hostname, os, datacenter_name)
    Puppet.info("#{log_prefix} node_create ip_hostname=#{ip_hostname}")
    Puppet.info("#{log_prefix} node_create os=#{os}")
    Puppet.info("#{log_prefix} node_create cm group=#{domain_details}")

    node = {}
    node[:node] = {}
    node[:node][:name] = "#{ip_hostname}"
    node[:node][:external_id] = "#{ip_hostname}"
    if test_env && TEST_OS == 'windows'
      ip_hostname = TEST_WINDOWS_HOSTNAME
    elsif test_env && TEST_OS == 'centos'
      ip_hostname = TEST_LINUX_HOSTNAME
    end
    node[:node][:medium_hostname] = "#{ip_hostname}"
    node[:node][:short_description] = "#{VERSION_TAG}"
    node[:node][:connection_manager_group_id] = "#{domain_details['id']}"
    node[:node][:medium_username] = "#{domain_details['service_account']}"
    node[:node][:medium_password] = "#{domain_details['service_password']}"

    if os && os.downcase == 'windows'
      node[:node][:node_type] = "SV" # Server
      node[:node][:operating_system_family_id] = 1
      node[:node][:operating_system_id] = 125 # Windows 2012
      node[:node][:medium_type] = 7 # WinRM
      node[:node][:medium_port] = 5985
    elsif os && os.downcase == 'centos'
      node[:node][:node_type] = "SV"
      node[:node][:operating_system_family_id] = 2
      node[:node][:operating_system_id] = 231 # CentOS
      node[:node][:medium_type] = 3 # SSH
      node[:node][:medium_port] = 22
    else # Add the node as a network device...
      node[:node][:node_type] = "FW" # Firewall
      node[:node][:operating_system_family_id] = 7
      node[:node][:operating_system_id] = 731 # Cisco ASA
      node[:node][:medium_type] = 3 # SSH
      node[:node][:medium_port] = 22
    end

    request = "curl -X POST -s -k -H 'Authorization: Token token=\"#{api_key}\"' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '#{node.to_json}' #{instance}/api/v2/nodes"
    Puppet.info("#{log_prefix} node_create request=#{request}")
    response = `#{request}`
    Puppet.info("#{log_prefix} node_create response=#{response}")
    node = JSON.load(response)

    if node["id"]
      if os && os.downcase != 'windows' && os.downcase != 'centos'
        Puppet.info("#{log_prefix} adding node to unclassified node group")
        unclassified_resp = upguard_add_to_node_group(api_key, instance, node["id"], UNKNOWN_OS_NODE_GROUP_ID)
        Puppet.info("#{log_prefix} adding node to unclassified node group response=#{unclassified_resp}")
      end

      node["id"]
    else
      Puppet.err("#{log_prefix} failed to create node: #{ip_hostname}")
      raise StandardError, "#{log_prefix} unable to create node: confirm node parameters are correct"
    end
  end
  module_function :upguard_node_create

  # Kick off a node scan
  def upguard_node_scan(api_key, instance, node_id, tag)
    response = `curl -X POST -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' #{instance}/api/v2/nodes/#{node_id}/start_scan.json?label=#{tag}`
    Puppet.info("#{log_prefix} node_scan response=#{response}")
    JSON.load(response)
  end
  module_function :upguard_node_scan

  # Kick off a vulnerability scan
  def upguard_node_vuln_scan(api_key, instance, node_id)
    response = `curl -X POST -s -k -H 'Authorization: Token token="#{api_key}"' -H 'Accept: application/json' -H 'Content-Type: application/json' '#{instance}/api/v2/jobs.json?type=node_vulns&vuln_limit=5000&vuln_severity=5&type_id=#{node_id}'`
    Puppet.info("#{log_prefix} node_vuln_scan response=#{response}")
    JSON.load(response)
  end
  module_function :upguard_node_vuln_scan
end
