require "rails_helper"

RSpec.describe HerokuCommands::Deploy, type: :model do
  include Helpers::Command::Deploy

  before do
    Lock.clear_deploy_locks!
  end

  def build_command(cmd)
    command = command_for(cmd)
    user = command.user
    user.github_token = Digest::SHA1.hexdigest(Time.now.utc.to_f.to_s)
    user.save
    command.user.reload
    command
  end

  # rubocop:disable Metrics/LineLength
  it "has a deploy command" do
    command = build_command("deploy hubot to production")
    stub_deploy_command(command.user.heroku_token)

    expect(command.task).to eql("deploy")
    expect(command.subtask).to eql("default")

    heroku_command = HerokuCommands::Deploy.new(command)

    response = heroku_command.run

    expect(heroku_command.pipeline_name).to eql("hubot")
    expect(response).to be_empty
  end

  it "alerts you if the environment is not found" do
    command = build_command("deploy hubot to mars")
    stub_deploy_command(command.user.heroku_token)

    expect(command.task).to eql("deploy")
    expect(command.subtask).to eql("default")

    heroku_command = HerokuCommands::Deploy.new(command)

    response = heroku_command.run

    expect(heroku_command.pipeline_name).to eql("hubot")
    expect(response[:response_type]).to eql("in_channel")
    expect(response[:text]).to eql(
      "Unable to find an environment called mars. " \
      "Available environments: production"
    )
  end

  it "responds to you if required commit statuses aren't present" do
    command = build_command("deploy hubot to production")
    heroku_token = command.user.heroku_token
    stub_account_info(heroku_token)
    stub_pipeline_info(heroku_token)
    stub_app_info(heroku_token)
    stub_app_is_not_2fa(heroku_token)
    stub_build(heroku_token)
    stub_request(:post, "https://api.github.com/repos/atmos/hubot/deployments")
      .to_return(status: 409, body: { message: "Conflict: Commit status checks failed for master." }.to_json, headers: {})

    expect(command.task).to eql("deploy")
    expect(command.subtask).to eql("default")

    heroku_command = HerokuCommands::Deploy.new(command)

    response = heroku_command.run

    expect(heroku_command.pipeline_name).to eql("hubot")
    expect(response[:response_type]).to eql("in_channel")
    expect(response[:text]).to be_nil
    expect(response[:attachments].size).to eql(1)
    attachment = response[:attachments].first
    expect(attachment[:text]).to eql(
      "Unable to create GitHub deployments for atmos/hubot: " \
      "Conflict: Commit status checks failed for master."
    )
  end

  it "prompts to unlock in the dashboard if the app is 2fa protected" do
    command = build_command("deploy hubot to production")
    heroku_token = command.user.heroku_token
    stub_account_info(heroku_token)
    stub_pipeline_info(heroku_token)
    stub_app_info(heroku_token)
    response_info = fixture_data("kolkrabbi.com/pipelines/531a6f90-bd76-4f5c-811f-acc8a9f4c111/repository") # rubocop:disable Metrics/LineLength
    stub_request(:get, "https://kolkrabbi.com/pipelines/531a6f90-bd76-4f5c-811f-acc8a9f4c111/repository") # rubocop:disable Metrics/LineLength
      .to_return(status: 200, body: response_info)
    stub_request(:get, "https://api.heroku.com/apps/27bde4b5-b431-4117-9302-e533b887faaa/config-vars")
      .with(headers: default_heroku_headers(command.user.heroku_token))
      .to_return(status: 403, body: { id: "two_factor" }.to_json, headers: {})

    expect(command.task).to eql("deploy")
    expect(command.subtask).to eql("default")

    heroku_command = HerokuCommands::Deploy.new(command)

    response = heroku_command.run

    expect(heroku_command.pipeline_name).to eql("hubot")
    expect(response[:text]).to be_nil
    expect(response[:response_type]).to be_nil
    attachments = [
      {
        text: "<https://dashboard.heroku.com/apps/hubot|hubot> " \
        "requires a second factor for access."
      }
    ]
    expect(response[:attachments]).to eql(attachments)
  end

  it "locks on second attempt" do
    command = command_for("deploy hubot to production")
    heroku_command = HerokuCommands::Deploy.new(command)
    heroku_command.user.github_token = SecureRandom.hex(24)
    heroku_command.user.save

    heroku_token = command.user.heroku_token

    stub_pipeline_info(heroku_token)
    stub_app_info(heroku_token)
    response_info = fixture_data("kolkrabbi.com/pipelines/531a6f90-bd76-4f5c-811f-acc8a9f4c111/repository") # rubocop:disable Metrics/LineLength
    stub_request(:get, "https://kolkrabbi.com/pipelines/531a6f90-bd76-4f5c-811f-acc8a9f4c111/repository") # rubocop:disable Metrics/LineLength
      .to_return(status: 200, body: response_info)

    # Fake the lock
    Lock.new("escobar-app-27bde4b5-b431-4117-9302-e533b887faaa").lock

    response = heroku_command.run

    attachments = [
      {
        text: "Someone is already deploying to hubot",
        color: "#f00"
      }
    ]
    expect(response[:attachments]).to eql(attachments)
  end

  it "responds with an error message if the pipeline is not connected to GitHub" do
    command = command_for("deploy hubot to production")
    heroku_command = HerokuCommands::Deploy.new(command)
    heroku_command.user.github_token = SecureRandom.hex(24)
    heroku_command.user.save

    heroku_token = command.user.heroku_token

    stub_pipeline_info(heroku_token)
    stub_app_info(heroku_token)
    stub_request(:get, "https://kolkrabbi.com/pipelines/531a6f90-bd76-4f5c-811f-acc8a9f4c111/repository") # rubocop:disable Metrics/LineLength
      .to_return(status: 404, body: {}.to_json)

    expect(command.task).to eql("deploy")
    expect(command.subtask).to eql("default")

    heroku_command = HerokuCommands::Deploy.new(command)

    response = heroku_command.run

    expect(response[:response_type]).to eql("in_channel")
    expect(response[:text]).to eql(
      "<https://dashboard.heroku.com/pipelines/" \
      "531a6f90-bd76-4f5c-811f-acc8a9f4c111|Connect your pipeline to GitHub>"
    )
  end

  it "responds with an error message if the pipeline contains more than one app" do
    command = build_command("deploy pipeline-with-multiple-apps to production")
    stub_deploy_command(command.user.heroku_token)

    expect(command.task).to eql("deploy")
    expect(command.subtask).to eql("default")

    heroku_command = HerokuCommands::Deploy.new(command)

    response = heroku_command.run

    expect(heroku_command.pipeline_name).to eql("pipeline-with-multiple-apps")
    pipeline_name = "pipeline-with-multiple-apps"
    stage = "production"
    apps = "beeper-production, beeper-production-foo"
    attachments = [
      {
        text: "There is more than one app in the #{pipeline_name} #{stage} stage: #{apps}. This is not supported yet.",
        color: "#f00"
      }
    ]
    expect(response[:attachments]).to eql(attachments)
  end

  it "deploys an application if the pipeline has multiple apps and an app is specified" do
    command = build_command("deploy pipeline-with-multiple-apps to production/beeper-production-foo")
    stub_deploy_command(command.user.heroku_token)

    expect(command.task).to eql("deploy")
    expect(command.subtask).to eql("default")

    heroku_command = HerokuCommands::Deploy.new(command)

    response = heroku_command.run

    expect(heroku_command.pipeline_name).to eql("pipeline-with-multiple-apps")
    expect(response).to be_empty
  end
end
