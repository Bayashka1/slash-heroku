module HerokuCommands
  # Class for handling pipeline requests
  class Pipelines < HerokuCommand
    include ChatOpsPatterns
    include PipelineResponse

    def initialize(command)
      super(command)
    end

    def self.help_documentation
      [
        "pipelines - View available pipelines.",
        "pipelines:info -a APP - View detailed information for a pipeline."
      ]
    end

    def run
      @response = run_on_subtask
    rescue StandardError => e
      raise e if Rails.env.test?
      Raven.capture_exception(e)
      response_for("Unable to fetch pipeline info for #{application}.")
    end

    def run_on_subtask
      case subtask
      when "info"
        pipeline_info
      when "list", "default"
        response_for("You can deploy: #{pipelines.app_names.join(', ')}.")
      else
        response_for("pipeline:#{subtask} is currently unimplemented.")
      end
    rescue Escobar::GitHub::RepoNotFound
      response_for("You're not authenticated with GitHub. " \
                   "<#{command.github_auth_url}|Fix that>.")
    end
  end
end
