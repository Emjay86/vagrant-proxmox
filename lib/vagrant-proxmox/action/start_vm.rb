module VagrantPlugins
	module Proxmox
		module Action

			# This action starts the Proxmox virtual machine in env[:machine]
			class StartVm < ProxmoxAction

				def initialize app, env
					@app = app
					@logger = Log4r::Logger.new 'vagrant_proxmox::action::start_vm'
				end

				def call env
					env[:ui].info I18n.t('vagrant_proxmox.starting_vm')
					begin
						node, vm_id = env[:machine].id.split '/'
						exit_status = connection(env).start_vm vm_id
						exit_status == 'OK' ? exit_status : raise(VagrantPlugins::Proxmox::Errors::ProxmoxTaskFailed, proxmox_exit_status: exit_status)
					rescue StandardError => e
						raise VagrantPlugins::Proxmox::Errors::VMStartError, proxmox_exit_status: e.message
					end

					retryException = Class.new StandardError

					retryable(on: Errors::VMNotPingable,
										tries: env[:machine].provider_config.task_timeout,
										sleep: env[:machine].provider_config.task_status_check_interval ) do
									env[:ui].detail "ping to #{vm_id} on #{node} timed out, retrying..."
									connection(env).qemu_agent_ping(node, vm_id)
					end

					env[:ui].info I18n.t('vagrant_proxmox.waiting_for_ssh_connection')

					begin
						retryable(on: retryException,
											tries: env[:machine].provider_config.ssh_timeout / env[:machine].provider_config.ssh_status_check_interval + 1,
											sleep: env[:machine].provider_config.ssh_status_check_interval) do
							env[:ui].detail "Waiting for #{vm_id} on #{node} to become ready for communication..."
							unless env[:interrupted] || env[:machine].communicate.ready?
								raise retryException
							end
						end
					rescue retryException
						raise VagrantPlugins::Proxmox::Errors::SSHError
					end

					$machine_state_changed = true
					next_action env
				end

			end

		end
	end
end
