require 'vagrant-proxmox/proxmox/errors'
require 'rest-client'
require 'retryable'
require 'required_parameters'
require 'date'

module VagrantPlugins
  module Proxmox
    class Connection
      include RequiredParameters

      attr_reader :api_url
      attr_reader :ticket
      attr_reader :csrf_token
      attr_accessor :vm_id_range
      attr_accessor :task_timeout
      attr_accessor :task_status_check_interval
      attr_accessor :imgcopy_timeout
      attr_accessor :verify_ssl

      def initialize(api_url, ui, opts = {})
        @api_url = api_url
        @vm_id_range = opts[:vm_id_range] || (900..999)
        @task_timeout = opts[:task_timeout] || 60
        @task_status_check_interval = opts[:task_status_check_interval] || 2
        @imgcopy_timeout = opts[:imgcopy_timeout] || 120
        @verify_ssl = opts[:verify_ssl]
        @ui = ui
      end

      def login(username: required('username'), vagrantfile_path: required('vagrantfile_path'))
        if $ticket.nil? || $csrf_token.nil?
          if File.file?("#{vagrantfile_path}/.proxmox_token")
            json = File.read("#{vagrantfile_path}/.proxmox_token")
            data = JSON.parse(json)
            token_age = Time.parse(data['date'])
            max_token_age = Time.now.getutc - (2 * 60 * 60)

            if  max_token_age.to_i > token_age.to_i
              @ui.warn "Token expired"
              get_new_login username: username, vagrantfile_path: vagrantfile_path
            else
              $ticket = data['ticket']
              $csrf_token = data['csrf_token']
            end
          else
            get_new_login username: username, vagrantfile_path: vagrantfile_path
          end
        end
      end

      def get_new_login(username: required('username'), vagrantfile_path: required('vagrantfile_path'))
        printf "Proxmox password: "
        password = STDIN.noecho(&:gets).chomp.to_s
        puts

        begin
          response = post '/access/ticket', username: username, password: password
          date = Time.now.getutc
          $ticket = response[:data][:ticket]
          $csrf_token = response[:data][:CSRFPreventionToken]
          json = {
            'date' => date,
            'ticket' => $ticket,
            'csrf_token' => $csrf_token
          }

          File.open("#{vagrantfile_path}/.proxmox_token", "w") do |file|
            file.puts(JSON.dump(json))
          end
        rescue ApiError::ServerError
          raise ApiError::InvalidCredentials
        rescue => x
          raise ApiError::ConnectionError, x.message
        end
      end

      def get_node_list
        nodelist = get '/nodes'
        nodelist[:data].map { |n| n[:node] }
      end

      def get_vm_state(vm_id)
        vm_info = get_vm_info vm_id
        if vm_info
          begin
            response = get "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/current"
            states = { 'running' => :running,
                       'stopped' => :stopped }
            states[response[:data][:status]]
          rescue ApiError::ServerError
            :not_created
          end
        else
          :not_created
        end
      end

      def wait_for_completion(task_response: required('task_response'), timeout_message: required('timeout_message'))
        task_upid = task_response[:data]
        timeout = task_timeout
        task_type = /UPID:.*?:.*?:.*?:.*?:(.*)?:.*?:.*?:/.match(task_upid)[1]
        timeout = imgcopy_timeout if task_type == 'imgcopy'
        begin
          retryable(on: VagrantPlugins::Proxmox::ProxmoxTaskNotFinished,
                    tries: timeout / task_status_check_interval + 1,
                    sleep: task_status_check_interval) do
            log = get_task_log task_upid
            @ui.detail log.last[:t] if log.last[:t] != "no content"
            # print_task_log log
            exit_status = get_task_exitstatus task_upid
            exit_status.nil? ? raise(VagrantPlugins::Proxmox::ProxmoxTaskNotFinished) : exit_status
          end
        rescue VagrantPlugins::Proxmox::ProxmoxTaskNotFinished
          raise VagrantPlugins::Proxmox::Errors::Timeout, timeout_message
        end
      end

      def delete_vm(vm_id)
        vm_info = get_vm_info vm_id
        response = delete "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}"
        wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.destroy_vm_timeout'
      end

      def create_vm(node: required('node'), vm_type: required('node'), params: required('params'))
        response = post "/nodes/#{node}/#{vm_type}", params
        wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.create_vm_timeout'
      end

      def clone_vm(node: required('node'), vm_type: required('node'), params: required('params'))
        vm_id = params[:vmid]
        params.delete(:vmid)
        params.delete(:ostype)
        params.delete(:ide2)
        params.delete(:sata0)
        params.delete(:sockets)
        params.delete(:cores)
        params.delete(:description)
        params.delete(:memory)
        params.delete(:net0)
        response = post "/nodes/#{node}/#{vm_type}/#{vm_id}/clone", params
        wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.create_vm_timeout'
      end

      def config_clone(node: required('node'), vm_type: required('node'), params: required('params'))
        vm_id = params[:vmid]
        params.delete(:vmid)
        response = post "/nodes/#{node}/#{vm_type}/#{vm_id}/config", params
        wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.create_vm_timeout'
      end

      def get_vm_config(vm_id: required('node'), vm_type: required('node'))
        node = get_vm_info(vm_id)[:node]
        response = get "/nodes/#{node}/#{vm_type}/#{vm_id}/config"
        response = response[:data]
        response.empty? ? raise(VagrantPlugins::Proxmox::Errors::VMConfigError) : response
      end

      def start_vm(vm_id)
        vm_info = get_vm_info vm_id
        response = post "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/start", nil
        wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.start_vm_timeout'
      end

      def stop_vm(vm_id)
        vm_info = get_vm_info vm_id
        response = post "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/stop", nil
        wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.stop_vm_timeout'
      end

      def shutdown_vm(vm_id)
        vm_info = get_vm_info vm_id
        response = post "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/shutdown", nil
        wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.shutdown_vm_timeout'
      end

      def get_free_vm_id
        # to avoid collisions in multi-vm setups
        sleep (rand(1..3) + 0.1 * rand(0..9))
        response = get '/cluster/resources?type=vm'
        allowed_vm_ids = vm_id_range.to_set
        used_vm_ids = response[:data].map { |vm| vm[:vmid] }
        free_vm_ids = (allowed_vm_ids - used_vm_ids).sort
        free_vm_ids.empty? ? raise(VagrantPlugins::Proxmox::Errors::NoVmIdAvailable) : free_vm_ids.first
      end

      def get_qemu_vm_data()
        response = get '/cluster/resources?type=vm'
        response[:data]
      end

      def get_qemu_template_id(data, template)
        found_ids = data.select { |vm| vm[:type] == 'qemu' }.select { |vm| vm[:template] == 1 }.select { |vm| vm[:name] == template }.map { |vm| vm[:vmid] }
        found_ids.empty? ? raise(VagrantPlugins::Proxmox::Errors::NoTemplateAvailable) : found_ids.first
      end

      def get_qemu_template_residing_node(data, template)
        node = data.select { |vm| vm[:type] == 'qemu' }.select { |vm| vm[:template] == 1 }.select { |vm| vm[:name] == template }.map { |vm| vm[:node] }
        node.empty? ? raise(VagrantPlugins::Proxmox::Errors::NoTemplateAvailable) : node.first
      end

      def get_qemu_vm_residing_node(data, vm_id)
        # node = data.select { |vm| vm[:type] == 'qemu' }.select { |vm| vm[:vmid] == vm_id }.map { |vm| vm[:node] }
        node = data.select { |vm| vm[:type] == 'qemu' }.select { |vm| vm[:vmid] == vm_id.to_i }.map { |vm| vm[:node] }
        node.empty? ? raise(VagrantPlugins::Proxmox::Errors::NoVmIdAvailable) : node.first
      end

      def upload_file(file, content_type: required('content_type'), node: required('node'), storage: required('storage'), replace: false)
        delete_file(filename: file, content_type: content_type, node: node, storage: storage) if replace
        unless is_file_in_storage? filename: file, node: node, storage: storage
          res = post "/nodes/#{node}/storage/#{storage}/upload", content: content_type,
                                                                 filename: File.new(file, 'rb'), node: node, storage: storage
          wait_for_completion task_response: res, timeout_message: 'vagrant_proxmox.errors.upload_timeout'
        end
      end

      def delete_file(filename: required('filename'), content_type: required('content_type'), node: required('node'), storage: required('storage'))
        delete "/nodes/#{node}/storage/#{storage}/content/#{content_type}/#{File.basename filename}"
      end

      def list_storage_files(node: required('node'), storage: required('storage'))
        res = get "/nodes/#{node}/storage/#{storage}/content"
        res[:data].map { |e| e[:volid] }
      end

      def get_node_ip(node, interface)
        response = get "/nodes/#{node}/network/#{interface}"
        response[:data][:address]
      rescue ApiError::ServerError
        :not_created
      end

      def qemu_agent_ping(node, vm_id)
        begin
          post "/nodes/#{node}/qemu/#{vm_id}/agent", command: "ping"
        rescue ApiError::ServerError => e
          raise Errors::VMNotPingable, e.message
        end
      end

      def qemu_agent_get_vm_ip(node, vm_id)
        qemu_agent_ping(node, vm_id)

        retryException = Class.new StandardError

        response = nil
        result = nil
        interfaces = {}

        retryable(on: retryException, tries: 3, sleep: 5) do
          response = post "/nodes/#{node}/qemu/#{vm_id}/agent", command: "network-get-interfaces"
          begin
            result = response[:data][:result]
              .select { |iface| iface[:name] != 'lo' }
              .map { |iface| iface[:'ip-addresses'] }
              .flatten
              .select { |ip| ip[:'ip-address-type'] == 'ipv4' }
              .map { |ip| ip[:'ip-address'] }
              .first
          rescue NoMethodError
            interfaces = {}
            response[:data][:result].each do |x|
              interfaces[x[:name]] = []

              x[:"ip-addresses"].each do |ip|
                interfaces[x[:name]].push ip[:"ip-address"]
              end if x[:"ip-addresses"]
            end
            raise VagrantPlugins::Proxmox::Errors::NoValidIPv4.new interfaces: interfaces
          end

          # The Agent Ping is successful with a IPv6 as well, but we need a valid IPv4 address,
          # therefor network-get-interfaces could return only a IPv6 address, so we retry to get a valid IPv4 address
          unless result
            raise retryException
          end
        end

        result

      rescue StandardError
        raise VagrantPlugins::Proxmox::Errors::NoValidIPv4.new interfaces: interfaces
      end

      def get_qemu_current_config(node,vm_id)
        response = get "/nodes/#{node}/qemu/#{vm_id}/config"
        response[:data]
      end

      def find_qemu_vm(name_prefix, vm_name)
        cluster_data = get_qemu_vm_data()
        vm_data = cluster_data.select { |vm| vm[:type] == 'qemu' }.select { |vm| vm[:name] == "#{name_prefix}#{vm_name}" }
        if !vm_data.empty?
          "#{vm_data.first[:node]}/#{vm_data.first[:id].split('/').last}"
        else
          nil
        end
      end

      # This is called every time to retrieve the node and vm_type, hence on large
      # installations this could be a huge amount of data. Probably an optimization
      # with a buffer for the machine info could be considered.

      private

      def get_vm_info(vm_id)
        response = get '/cluster/resources?type=vm'
        response[:data]
          .select { |m| m[:id] =~ /^[a-z]*\/#{vm_id}$/ }
          .map { |m| { id: vm_id, type: /^(.*)\/(.*)$/.match(m[:id])[1], node: m[:node] } }
          .first
      end

      private

      def get_task_exitstatus(task_upid)
        node = /UPID:(.*?):/.match(task_upid)[1]
        response = get "/nodes/#{node}/tasks/#{task_upid}/status"
        response[:data][:exitstatus]
      end

      def get_task_log(task_upid)
        node = /UPID:(.*?):/.match(task_upid)[1]
        response = get "/nodes/#{node}/tasks/#{task_upid}/log?limit=500"
        response[:data]
      end

      def print_task_log(log)
        log.each do |data|
          @ui.detail data[:t] if data[:t] != "no content"
        end
      end

      private

      def get(path)
        response = RestClient::Request.execute(:method => :get, :url => "#{api_url}#{path}", :headers => { cookies: { PVEAuthCookie: $ticket } }, :verify_ssl => verify_ssl )
        JSON.parse response.to_s, symbolize_names: true
      rescue RestClient::NotImplemented
        raise ApiError::NotImplemented
      rescue RestClient::InternalServerError => e
        raise ApiError::ServerError, e.message
      rescue RestClient::Unauthorized
        raise ApiError::UnauthorizedError
      rescue => x
        raise ApiError::ConnectionError, x.message
      end

      private

      def delete(path, _params = {})
        response = RestClient::Request.execute(:method => :delete, :url => "#{api_url}#{path}", :headers => headers, :verify_ssl => verify_ssl)
        JSON.parse response.to_s, symbolize_names: true
      rescue RestClient::Unauthorized
        raise ApiError::UnauthorizedError
      rescue RestClient::NotImplemented
        raise ApiError::NotImplemented
      rescue RestClient::InternalServerError
        raise ApiError::ServerError
      rescue => x
        raise ApiError::ConnectionError, x.message
      end

      private

      def post(path, params = {})
        response = RestClient::Request.execute(:method => :post, :url => "#{api_url}#{path}", :payload => params, :headers => headers, :verify_ssl => verify_ssl)
        JSON.parse response.to_s, symbolize_names: true
      rescue RestClient::Unauthorized
        raise ApiError::UnauthorizedError
      rescue RestClient::NotImplemented
        raise ApiError::NotImplemented
      rescue RestClient::InternalServerError
        raise ApiError::ServerError
      rescue => x
        raise ApiError::ConnectionError, x.message
      end

      private

      def headers
        $ticket.nil? ? {} : { CSRFPreventionToken: $csrf_token, cookies: { PVEAuthCookie: $ticket } }
      end

      private

      def is_file_in_storage?(filename: required('filename'), node: required('node'), storage: required('storage'))
        (list_storage_files node: node, storage: storage).find { |f| f =~ /#{File.basename filename}/ }
      end
    end
  end
end
