module VagrantPlugins
	module Proxmox
		module Action

			class CleanupAfterDestroy < ProxmoxAction

				def initialize app, env
					@app = app
				end

				def call env
					Dir[".vagrant/machines/#{env[:machine].name}/proxmox/*"].each do |file|
						FileUtils.rm_rf file unless file.to_s.match(/vagrant_cwd$/)
					end
					next_action env
				end

			end

		end
	end
end
