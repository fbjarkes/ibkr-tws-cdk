param(
  [Parameter(Mandatory)][ValidateSet('start','stop','status','session','down')][string]$Action,
  [string]$Profile = 'poweruser',
  [string]$Region = '',
  [switch]$ApplicationsClosed
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
  'session' { Invoke-Aws -CliArgs @('ssm','start-session','--target',$instance) }
  'start' {
    Invoke-Aws -CliArgs @('ec2','start-instances','--instance-ids',$instance) | Out-Null
    Invoke-Aws -CliArgs @('ec2','wait','instance-status-ok','--instance-ids',$instance)
    Write-Host 'EC2 checks passed. Use the status command to obtain the current public IPv4 for RDP; desktop services may need a little longer to start.'
  }
  { $_ -in 'stop','down' } {
    $state = Invoke-Aws -CliArgs @('ec2','describe-instances','--instance-ids',$instance,'--query','Reservations[0].Instances[0].State.Name','--output','text')
    if ($state -ne 'stopped') {
      if ($state -ne 'running') { throw "Wait for a stable instance state; current state: $state" }
      if (-not $ApplicationsClosed) { throw 'Save work and close TWS/browser/LibreOffice, then pass -ApplicationsClosed. No forced application shutdown is performed.' }
      $check = @'
set -eu
if pgrep -u trader -f '(^|/)(java|soffice.bin|firefox|herdr)( |$)' >/dev/null; then echo 'Close desktop applications and stop Herdr sessions first'; exit 1; fi
if mountpoint -q /mnt/watchlists; then
  sync -f /mnt/watchlists
  umount /mnt/watchlists
fi
if systemctl is-active --quiet tws-s3fs.service; then
  systemctl stop tws-s3fs.service
fi
sync
'@
      # A CRLF checkout on Windows would hand bash 'set -eu\r' and break every stop.
      $check = $check -replace "`r", ''
      $parameterFile = Join-Path ([IO.Path]::GetTempPath()) ("tws-command-" + [guid]::NewGuid() + '.json')
      try {
        @{ commands = @($check) } | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $parameterFile
        $commandId = Invoke-Aws -CliArgs @('ssm','send-command','--instance-ids',$instance,'--document-name','AWS-RunShellScript','--parameters',"file://$parameterFile",'--query','Command.CommandId','--output','text')
        # The waiter exits non-zero on a failed command; read the invocation for the real reason.
        & aws ssm wait command-executed --command-id $commandId --instance-id $instance --profile $Profile --region $Region 2>$null
        $result = Invoke-Aws -CliArgs @('ssm','get-command-invocation','--command-id',$commandId,'--instance-id',$instance,'--output','json') | ConvertFrom-Json
        if ($result.Status -ne 'Success') { throw "Shutdown checks failed: $($result.StandardErrorContent) $($result.StandardOutputContent)" }
      } finally { Remove-Item -LiteralPath $parameterFile -ErrorAction SilentlyContinue }
      Invoke-Aws -CliArgs @('ec2','stop-instances','--instance-ids',$instance) | Out-Null
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
