require 'vagrant/util/subprocess'

module VagrantPlugins
	module Proxmox
		module Action

			# This action uses 'rsync' to sync the folders over to the virtual machine.
			class PostProvision < ProxmoxAction

				def initialize app, env
					@app = app
					@logger = Log4r::Logger.new 'vagrant_proxmox::action::post_provision'
					@provisioner_count = env[:machine].config.vm.provisioners.count
					$finished_provisioners = {} unless $finished_provisioners
				end

				def call env
					machine_name = env[:machine].name
          $finished_provisioners[machine_name] = 1 unless $finished_provisioners.key?(machine_name)

          if @provisioner_count == $finished_provisioners[env[:machine].name]
						config = env[:machine].provider_config
						params = {}

						if config.qemu_vlan
						  vm_id = env[:machine].id.split("/").last

						  begin
						    data = connection(env).get_qemu_vm_data()
						  rescue StandardError => e
						  	raise VagrantPlugins::Proxmox::Errors::VMConfigError, error_msg: e.message
						  end

						  begin
						    node = connection(env).get_qemu_vm_residing_node(data, vm_id)
						  rescue StandardError => e
						  	raise VagrantPlugins::Proxmox::Errors::VMConfigError, error_msg: e.message
						  end

							current_config = connection(env).get_qemu_current_config(node, vm_id)
							params[:vmid] = env[:machine].id.split("/").last

						  config.qemu_vlan.each do |interface, vlan|
								desired_config = "#{config.qemu_nic_model},bridge=#{config.qemu_bridge},tag=#{vlan}"
								current_vlan = current_config[interface.to_sym].match(/tag=(\d+)/)[1]
								if current_vlan.to_s == vlan.to_s
									env[:ui].detail "VLAN #{vlan} is already set for interface #{interface}!"
								else
							    env[:ui].detail "Changing VLAN of #{interface} --> #{vlan}"

							    params[interface] = "#{config.qemu_nic_model},bridge=#{config.qemu_bridge},tag=#{vlan}"
								end
						  end
						end

						# private_key_path = env[:machine].ssh_info[:private_key_path]
						# private_key = ""
						# File.open(private_key_path.first,"r") do |file|
						# 	while (line = file.gets)
						# 		private_key << line
						# 	end
						# end
						#
						# if current_config[:description].to_s != private_key
						# 	env[:ui].detail "Putting Private Key into description of VM"
						# 	params[:description] = private_key
						# end

						if !params.except(:vmid).empty?
						  begin
						  	exit_status = connection(env).config_clone node: node, vm_type: config.vm_type, params: params
						  	exit_status == 'OK' ? exit_status : raise(VagrantPlugins::Proxmox::Errors::ProxmoxTaskFailed, proxmox_exit_status: exit_status)
						  rescue StandardError => e
						  	raise VagrantPlugins::Proxmox::Errors::VMConfigError, error_msg: e.message
						  end
						end
          else
            $finished_provisioners[machine_name] += 1
          end
					next_action env
				end
			end
		end
	end
end
