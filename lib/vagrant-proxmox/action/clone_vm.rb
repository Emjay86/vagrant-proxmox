module VagrantPlugins
	module Proxmox
		module Action

			# This action clones from a qemu template on the Proxmox server and
			# stores its node and vm_id env[:machine].id
			class CloneVm < ProxmoxAction

				def initialize app, env
					@app = app
					@logger = Log4r::Logger.new 'vagrant_proxmox::action::clone_vm'
				end

				def call env
					env[:ui].info I18n.t('vagrant_proxmox.cloning_vm')
					config = env[:machine].provider_config

					selected_node = env[:proxmox_selected_node]
					vm_id = nil
					template_vm_id = nil
					template_data = nil
					template_residing_node = nil

					begin
						template_data = connection(env).get_qemu_vm_data()
					rescue VagrantPlugins::Proxmox::ApiError::ServerError => e
						raise VagrantPlugins::Proxmox::Errors::VMCloneError, proxmox_exit_status: e.message
					end

					begin
						template_vm_id = connection(env).get_qemu_template_id(template_data, config.qemu_template)
					rescue VagrantPlugins::Proxmox::Errors::NoTemplateAvailable => e
						raise VagrantPlugins::Proxmox::Errors::VMCloneError, proxmox_exit_status: e.message
					end

					begin
						template_residing_node = connection(env).get_qemu_template_residing_node(template_data, config.qemu_template)
					rescue VagrantPlugins::Proxmox::Errors::NoTemplateAvailable => e
						raise VagrantPlugins::Proxmox::Errors::VMCloneError, proxmox_exit_status: e.message
					end

					begin
						vm_id = connection(env).get_free_vm_id
						if config.hostname_append_id
							hostname = env[:machine].config.vm.hostname
							env[:machine].config.vm.hostname = "#{hostname}#{vm_id}"
						end
						params = create_params_qemu(config, env, vm_id, template_vm_id, selected_node)
						exit_status = connection(env).clone_vm node: template_residing_node, vm_type: config.vm_type, params: params
						exit_status == 'OK' ? exit_status : raise(VagrantPlugins::Proxmox::Errors::ProxmoxTaskFailed, proxmox_exit_status: exit_status)
					rescue StandardError => e
						raise VagrantPlugins::Proxmox::Errors::VMCloneError, proxmox_exit_status: e.message
					end

					env[:machine].id = "#{selected_node}/#{vm_id}"
					$machine_state_changed = true

					next_action env
				end

				private
				def create_params_qemu(config, env, vm_id, template_vm_id, selected_node)
					vm_name = if config.vm_name_prefix
						if env[:machine].config.vm.hostname
							"#{config.vm_name_prefix}#{env[:machine].config.vm.hostname}"
						else
							"#{config.vm_name_prefix}#{env[:machine].name.to_s}"
						end
					else
						env[:machine].config.vm.hostname || env[:machine].name.to_s
					end

					# without network, which will added in ConfigClonedVm
					{
						vmid: template_vm_id,
						newid: vm_id,
						name: vm_name,
						target: selected_node,
						description: "#{config.vm_name_prefix}#{env[:machine].name}",
						pool: config.pool,
						full: get_rest_boolean(config.full_clone),
					}
				end

			end
		end
	end
end
