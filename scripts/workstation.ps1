param(
  [Parameter(Mandatory)][ValidateSet('start','stop','status','down')][string]$Action,
  [string]$Profile = 'poweruser',
  [string]$Region = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $Region) {
  $settings = Get-Content -Raw (Join-Path $projectRoot 'config/workstation.json') | ConvertFrom-Json
  $Region = $settings.region
  $localFile = Join-Path $projectRoot 'config/local.json'
  if (Test-Path $localFile) {
    $localSettings = Get-Content -Raw $localFile | ConvertFrom-Json
    if ($localSettings.region) { $Region = $localSettings.region }
  }
}
function Invoke-Aws {
  param([string[]]$CliArgs)
  $result = & aws @CliArgs --profile $Profile --region $Region
  if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: $($CliArgs[0..1] -join ' ')" }
  return $result
}
$instance = Invoke-Aws -CliArgs @('cloudformation','describe-stacks','--stack-name','TwsDesktop','--query',"Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]",'--output','text')
if ($instance -notmatch '^i-[a-f0-9]+$') { throw 'Could not resolve desktop instance ID' }
switch ($Action) {
  'status' { Invoke-Aws -CliArgs @('ec2','describe-instances','--instance-ids',$instance,'--query','Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Type:InstanceType,PublicIp:PublicIpAddress}','--output','table') }
  'start' {
    Invoke-Aws -CliArgs @('ec2','start-instances','--instance-ids',$instance) | Out-Null
    Invoke-Aws -CliArgs @('ec2','wait','instance-status-ok','--instance-ids',$instance)
    Write-Host 'EC2 checks passed. Use the status command to obtain the current public IPv4 for RDP; desktop services may need a little longer to start.'
  }
  { $_ -in 'stop','down' } {
    $state = Invoke-Aws -CliArgs @('ec2','describe-instances','--instance-ids',$instance,'--query','Reservations[0].Instances[0].State.Name','--output','text')
    if ($state -eq 'running') {
      # Normal EC2 OS shutdown: application/SSH checks must not block stopping.
      Invoke-Aws -CliArgs @('ec2','stop-instances','--instance-ids',$instance,'--no-force','--no-skip-os-shutdown') | Out-Null
    } elseif ($state -notin @('stopped','stopping')) {
      throw "Wait for a stable instance state; current state: $state"
    }
    if ($state -ne 'stopped') {
      Invoke-Aws -CliArgs @('ec2','wait','instance-stopped','--instance-ids',$instance)
    }
    if ($Action -eq 'down') {
      Push-Location $projectRoot
      $npx = if ($IsWindows) { 'npx.cmd' } else { 'npx' }
      try { & $npx cdk destroy TwsDesktop --profile $Profile; if ($LASTEXITCODE -ne 0) { throw 'CDK destroy failed' } }
      finally { Pop-Location }
    }
  }
}
