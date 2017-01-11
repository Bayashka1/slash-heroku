module HerokuCommands
  # Class for handling Deployment requests
  class Deploy < HerokuCommand
    include ChatOpsPatterns
    include PipelineResponse

    attr_reader :info
    delegate :application, :branch, :forced, :hosts, :second_factor, to: :@info

    def initialize(command)
      super(command)

      @info = chat_deployment_request(command.command_text)
    end

    def self.help_documentation
      [
        "deploy <pipeline>/<branch> to <env>/<roles> - deploy <pipeline>"
      ]
    end

    def run
      @response = run_on_subtask
    end

    def environment
      @environment ||= info.environment || pipeline.default_environment
    end

    def custom_payload
      {
        notify: {
          room: command.channel_name,
          user: command.user.slack_user_id,
          team_id: command.team_id,
          user_name: command.user.slack_user_name
        }
      }
    end

    def command_expired?
      command.created_at < 60.seconds.ago
    end

    def handle_locked_application(error)
      CommandExecutorJob
        .set(wait: 2.seconds)
        .perform_later(command_id: command.id) unless command_expired?

      if command.processed_at.nil?
        error_response_for_escobar(error)
      else
        {}
      end
    end

    # rubocop:disable Metrics/AbcSize
    def deploy_application
      if application && !pipelines[application]
        response_for("Unable to find a pipeline called #{application}")
      else
        user_id    = command.user.slack_user_id
        pipeline   = pipelines[application]

        begin
          deployment = pipeline.create_deployment(branch, environment,
                                                  forced, custom_payload)
          deployment.command_id = command.id

          DeploymentReaperJob
            .set(wait: 10.seconds)
            .perform_later(deployment.to_job_json)

          url = deployment.dashboard_build_output_url
          response_for("<@#{user_id}> is <#{url}|deploying> " \
                       "#{deployment.repository}@#{branch}" \
                       "(#{deployment.sha[0..7]}) to #{environment}.")
        rescue Escobar::Heroku::BuildRequest::Error => e
          handle_locked_application(e)
        rescue StandardError => e
          error_response_for(e.message)
        end
      end
    end

    def deployment_complete_message(payload, sha)
      url = payload[:target_url]
      suffix = payload[:state] == "success" ? "was successful" : "failed"
      user_id = command.user.slack_user_id
      duration = Time.now.utc - command.created_at.utc

      response_for("<@#{user_id}>'s <#{url}|#{environment}> deployment of " \
                   "#{pipeline.github_repository}@#{branch}" \
                   "(#{sha[0..7]}) #{suffix}. #{duration.round}s")
    end
    # rubocop:enable Metrics/AbcSize

    def run_on_subtask
      case subtask
      when "default"
        if pipelines
          deploy_application
        else
          response_for("You're not authenticated with GitHub yet. " \
                       "<#{command.github_auth_url}|Fix that>.")
        end
      else
        response_for("deploy:#{subtask} is currently unimplemented.")
      end
    rescue StandardError => e
      raise e if Rails.env.test?
      Raven.capture_exception(e)
      response_for("Unable to fetch deployment info for #{application}.")
    end

    def repository_markup(deploy)
      name_with_owner = deploy.github_repository
      "<https://github.com/#{name_with_owner}|#{name_with_owner}>"
    end
  end
end
