## Installs the Buildkite Agent, run from the CloudFormation template

Set-PSDebug -Trace 2

# Stop script execution when a non-terminating error occurs
$ErrorActionPreference = "Stop"

function on_error {
  $errorLine=$_.InvocationInfo.ScriptLineNumber
  $errorMessage=$_.Exception

  aws autoscaling set-instance-health `
    --instance-id "(Invoke-WebRequest -UseBasicParsing http://169.254.169.254/latest/meta-data/instance-id).content" `
    --health-status Unhealthy

  cfn-signal `
    --region "$Env:AWS_REGION" `
    --stack "$Env:BUILDKITE_STACK_NAME" `
    --reason "Error on line ${errorLine}: $errorMessage" `
    --resource "AgentAutoScaleGroup" `
    --exit-code 1
}

trap {on_error}

$Env:INSTANCE_ID=(Invoke-WebRequest -UseBasicParsing http://169.254.169.254/latest/meta-data/instance-id).content
$DOCKER_VERSION=(docker --version).split(" ")[2].Replace(",","")

$PLUGINS_ENABLED=@()
If ($Env:SECRETS_PLUGIN_ENABLED -eq "true") { $PLUGINS_ENABLED += "secrets" }
If ($Env:ECR_PLUGIN_ENABLED -eq "true") { $PLUGINS_ENABLED += "ecr" }
If ($Env:DOCKER_LOGIN_PLUGIN_ENABLED -eq "true") { $PLUGINS_ENABLED += "docker-login" }

# cfn-env is sourced by the environment hook in builds
Set-Content -Path C:\buildkite-agent\cfn-env -Value @"
export DOCKER_VERSION=$DOCKER_VERSION
export BUILDKITE_STACK_NAME=$Env:BUILDKITE_STACK_NAME
export BUILDKITE_STACK_VERSION=$Env:BUILDKITE_STACK_VERSION
export BUILDKITE_AGENTS_PER_INSTANCE=$Env:BUILDKITE_AGENTS_PER_INSTANCE
export BUILDKITE_SECRETS_BUCKET=$Env:BUILDKITE_SECRETS_BUCKET
export AWS_DEFAULT_REGION=$Env:AWS_REGION
export AWS_REGION=$Env:AWS_REGION
export PLUGINS_ENABLED="$PLUGINS_ENABLED"
export BUILDKITE_ECR_POLICY=$Env:BUILDKITE_ECR_POLICY
"@

If ($Env:BUILDKITE_AGENT_RELEASE -eq "edge") {
  Write-Output "Downloading buildkite-agent edge..."
  Invoke-WebRequest -OutFile C:\buildkite-agent\bin\buildkite-agent-edge.exe -Uri "https://download.buildkite.com/agent/experimental/latest/buildkite-agent-windows-amd64.exe"
  buildkite-agent-edge.exe --version
}

Copy-Item -Path C:\buildkite-agent\bin\buildkite-agent-${Env:BUILDKITE_AGENT_RELEASE}.exe -Destination C:\buildkite-agent\bin\buildkite-agent.exe

$agent_metadata=@(
  "queue=${Env:BUILDKITE_QUEUE}"
  "docker=${DOCKER_VERSION}"
  "stack=${Env:BUILDKITE_STACK_NAME}"
  "buildkite-aws-stack=${Env:BUILDKITE_STACK_VERSION}"
)

If (Test-Path Env:BUILDKITE_AGENT_TAGS) {
  $agent_metadata += $Env:BUILDKITE_AGENT_TAGS.split(",")
}

$OFS=","
Set-Content -Path C:\buildkite-agent\buildkite-agent.cfg -Value @"
name="${Env:BUILDKITE_STACK_NAME}-${Env:INSTANCE_ID}-%n"
token="${Env:BUILDKITE_AGENT_TOKEN}"
tags=$agent_metadata
tags-from-ec2=true
timestamp-lines=${Env:BUILDKITE_AGENT_TIMESTAMP_LINES}
hooks-path="C:\buildkite-agent\hooks"
build-path="C:\buildkite-agent\builds"
plugins-path="C:\buildkite-agent\plugins"
experiment="${Env:BUILDKITE_AGENT_EXPERIMENTS}"
priority=%n
shell=powershell
"@
$OFS=" "

If ($Env:BUILDKITE_TERMINATE_INSTANCE_AFTER_JOB -eq "true") {
  Add-Content -Path C:\buildkite-agent\buildkite-agent.cfg -Value @"
disconnect-after-job=true
disconnect-after-job-timeout=$Env:BUILDKITE_TERMINATE_INSTANCE_AFTER_JOB_TIMEOUT
"@
}

If (![string]::IsNullOrEmpty($Env:BUILDKITE_ELASTIC_BOOTSTRAP_SCRIPT)) {
  C:\buildkite-agent\bin\bk-fetch.ps1 -From "$Env:BUILDKITE_ELASTIC_BOOTSTRAP_SCRIPT" -To C:\buildkite-agent\elastic_bootstrap.ps1
  C:\buildkite-agent\elastic_bootstrap.ps1
  Remove-Item -Path C:\buildkite-agent\elastic_bootstrap.ps1
}

nssm set lifecycled AppEnvironmentExtra :AWS_REGION=$Env:AWS_REGION
nssm set lifecycled AppEnvironmentExtra +LIFECYCLED_SNS_TOPIC=$Env:BUILDKITE_LIFECYCLE_TOPIC
nssm set lifecycled AppEnvironmentExtra +LIFECYCLED_HANDLER="C:\buildkite-agent\bin\stop-agent-gracefully.ps1"
Restart-Service lifecycled

# wait for docker to start
$next_wait_time=0
do {
  Write-Output "Sleeping $next_wait_time seconds"
  Start-Sleep -Seconds ($next_wait_time++)
  docker ps
} until ($? -OR ($next_wait_time -eq 5))

docker ps
if (! $?) {
  echo "Failed to contact docker"
  exit 1
}

For ($i=1; $i -le ${Env:BUILDKITE_AGENTS_PER_INSTANCE}; $i++) {
  nssm install buildkite-agent-$i C:\buildkite-agent\bin\buildkite-agent.exe start
  nssm set buildkite-agent-$i AppStdout C:\buildkite-agent\buildkite-agent-$i.log
  nssm set buildkite-agent-$i AppStderr C:\buildkite-agent\buildkite-agent-$i.log
  nssm set buildkite-agent-$i AppEnvironmentExtra :HOME=C:\buildkite-agent
  If ($Env:BUILDKITE_TERMINATE_INSTANCE_AFTER_JOB -eq "true") {
    nssm set buildkite-agent-$i AppExit Default Exit
    nssm set buildkite-agent-$i AppEvents Exit/Post "powershell C:\buildkite-agent\bin\terminate-instance.ps1 $Env:BUILDKITE_TERMINATE_INSTANCE_AFTER_JOB_DECREASE_DESIRED_CAPACITY"
  }
  Restart-Service buildkite-agent-$i
}

# let the stack know that this host has been initialized successfully
cfn-signal `
  --region "$Env:AWS_REGION" `
  --stack "$Env:BUILDKITE_STACK_NAME" `
  --resource "AgentAutoScaleGroup" `
  --exit-code 0 ; if (-not $?) {
    # This will fail if the stack has already completed, for instance if there is a min size
    # of 1 and this is the 2nd instance. This is ok, so we just ignore the erro
    echo "Signal failed"
  }

Set-PSDebug -Off
