module VagrantPlugins
	module Proxmox

		class Provider < Vagrant.plugin('2', :provider)

			def initialize machine
				@machine = machine
				@machine_ssh_info = {}
				# The Provider Object is initialized more than once in a multi machine environment,
				# so we only initialize this var if it is nil.
				#
				# The general idea of this var is to prevent vagrant from querying proxmox about the state
				# of ths machine more than once (i observed several calls about the state of the machine,
				# before any action is called)
				if !$machine_state
					$machine_state = {}
				end
				$machine_state_changed = false
			end

			def action name
				# Attempt to get the action method from the Action class if it
				# exists, otherwise return nil to show that we don't support the
				# given action.

				action_method = "action_#{name}"
				return Action.send(action_method) if Action.respond_to?(action_method)
				nil
			end

			def state
				# Run a custom action we define called "read_state" which does
				# what it says. It puts the state in the `:machine_state_id`
				# key in the environment.
				env = @machine.action 'read_state'
				state_id = env[:machine_state_id]

				$machine_state[@machine.name] = state_id

				# Get the short and long description
				short = I18n.t "vagrant_proxmox.states.short_#{state_id}"
				long = I18n.t "vagrant_proxmox.states.long_#{state_id}"

				# Return the MachineState object
				Vagrant::MachineState.new state_id, short, long
			end

			def ssh_info
				# Run a custom action called "read_ssh_info" which does what it
				# says and puts the resulting SSH info into the `:machine_ssh_info`
				# key in the environment.

				if !@machine_ssh_info.key? @machine.name
					get_ssh_info()
				end
				@machine_ssh_info[@machine.name]
			end

			def to_s
				id = @machine.id.nil? ? 'new' : @machine.id
				"Proxmox (#{id})"
			end

			def get_ssh_info
				env = @machine.action 'read_ssh_info'
				@machine_ssh_info[@machine.name] = env[:machine_ssh_info]
			end

			def test_ssh_connection(test_try)
				command = "#{@machine.config.ssh.shell} -c 'date > /dev/null'"
				opts = {}
				opts[:extra_args] = []
				opts[:extra_args] << command
				opts[:subprocess] = true
				ssh_exit_status = Vagrant::Util::SSH.exec(@machine_ssh_info[@machine.name],opts)
				if ssh_exit_status != 0
					env[:ui].detail "SSH Test failed, retrieving it again..."
					if test_try <= 3
						test_try += 1
						get_ssh_info()
						test_ssh_connection(test_try)
					else
						env[:ui].detail "SSH Test failed, end of tries... exiting!"
					end
				end
			end
		end
	end
end
