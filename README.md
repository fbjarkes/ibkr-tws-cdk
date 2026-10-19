# ibkr-tws-cdk

First iteration of a persistent Ubuntu desktop for Interactive Brokers TWS. TypeScript CDK creates CloudFormation stacks. Nothing is deployed by cloning, installing dependencies, building, testing, or synthesizing.

## Design

- `TwsFoundation`: one public subnet in a fixed Availability Zone, no NAT gateway, encrypted retained 100 GiB gp3 data disk, daily snapshots at 02:00 UTC with seven retained snapshots. Foundation termination protection is enabled in the CDK app.
- `TwsDesktop`: On-Demand m7i.xlarge (4 vCPU / 16 GiB), Ubuntu 24.04 x86-64, encrypted disposable 40 GiB root disk, IMDSv2, SSM access and a narrowly scoped instance role. No SSH key.
- Public IPv4 enables outbound access. Only UDP 41641 (encrypted Tailscale transport) is open inbound. RDP is additionally bound to the Tailscale IPv4 address. There is no public RDP/SSH/TWS API listener. Define Tailscale grants restricting access to your own devices; tailnet membership alone is not the intended authorization policy.
- `/srv/tws/home` is bind-mounted at `/home/trader`. Put TWS and its settings there. `/srv/tws/tailscale` preserves the machine identity across exclusive rebuilds. Never run two instances with this data/identity. The instance is tied to the data volume's AZ; this is not high availability.
- Root packages are recreated on rebuild. Home files survive, but running sessions, unsaved work and the trader password do not. Set the password after each rebuild. Existing snapshots are crash-consistent; close apps before taking a manual snapshot for a known clean recovery point.

## Architecture

The diagram shows the current CDK configuration. TWS is installed manually, and the S3 data mount is optional.

```mermaid
flowchart TB
  client["Win11 / Debian / macOS<br/>RDP client + Tailscale"]
  dev["Developer workstation<br/>Git · CDK · AWS CLI"]
  ts["Tailscale coordination / relay<br/>External service"]
  ib["Interactive Brokers<br/>External service"]

  subgraph account["AWS account"]
    iam["AWS IAM<br/>EC2 instance role + instance profile<br/>Separate DLM service role"]
    subgraph region["AWS Region: eu-north-1 — Stockholm"]
      cf["AWS CloudFormation<br/>TwsFoundation + TwsDesktop"]
      assets["Amazon S3<br/>CDK bootstrap asset bucket<br/>Provisioning scripts and files"]
      s3["Amazon S3 — optional existing bucket<br/>Selected bucket / prefix<br/>Read-only by default"]
      ssm["AWS Systems Manager<br/>Session Manager / Run Command"]
      dlm["Amazon Data Lifecycle Manager<br/>Daily snapshots at 02:00 UTC"]
      snapshots["Amazon EBS snapshots<br/>Retain seven daily snapshots"]
        subgraph vpc["Amazon VPC — single-AZ subnet layout"]
          igw["Internet Gateway<br/>Public subnet route: 0.0.0.0/0"]
          subgraph subnet["Public subnet — eu-north-1a · no NAT gateway"]
            subgraph sg["Security group attached to EC2 ENI<br/>Inbound: UDP 41641 only · Outbound: all"]
              ec2["Amazon EC2 — m7i.xlarge<br/>Ubuntu 24.04 · 4 vCPU · 16 GiB<br/>Public IPv4 · IMDSv2 required<br/>Tailscale → xrdp / XFCE<br/>TWS installed manually · LibreOffice · browser<br/>SSM Agent · rclone"]
            end
          end
        end
        root["Amazon EBS — encrypted gp3 · 40 GiB<br/>Root OS disk · eu-north-1a<br/>Deleted with desktop instance"]
        data["Amazon EBS — encrypted gp3 · 100 GiB<br/>eu-north-1a · Home, TWS files, S3 cache<br/>Persistent Tailscale identity<br/>Retained across desktop rebuilds"]
    end
  end

  dev -->|"Deploy infrastructure"| cf
  dev -->|"Publish provisioning asset"| assets
  dev -->|"AWS-authenticated recovery and commands"| ssm
  cf -.->|"Provision / manage"| ec2
  cf -.->|"Provision / retain"| data
  client <-->|"Encrypted Tailscale tunnel<br/>RDP 3389 inside tunnel"| igw
  igw <--> ec2
  ec2 <-->|"Network path via Internet Gateway"| ts
  ec2 <-->|"Outbound network path via Internet Gateway"| ib
  ec2 -->|"HTTPS via Internet Gateway<br/>Download provisioning asset"| assets
  ec2 <-->|"HTTPS via Internet Gateway<br/>Optional rclone mount"| s3
  ec2 -->|"Outbound HTTPS via Internet Gateway"| ssm
  iam -.->|"Temporary role credentials"| ec2
  iam -.->|"Snapshot permissions"| dlm
  ec2 --- root
  ec2 --- data
  dlm -.->|"Snapshot tagged data volume"| data
  dlm --> snapshots
```

See [the detailed architecture documentation](docs/architecture.md) for stack ownership, resource lifecycle, and access details.

## Prerequisites

Node.js 22 LTS (current maintained patch) or newer supported LTS, npm, AWS CLI v2, PowerShell 7, and the Session Manager plugin. AWS profile `poweruser` must be authenticated. Creating/passing IAM roles, CloudFormation, EC2, DLM and CDK asset permissions are needed; the profile name does not establish permissions. If these are missing, use an administrator-approved deployment role.

## Configure and validate

```powershell
npm ci
# Optional: copy config/workstation.json to config/local.json and edit overrides.
npm run build
npm test
npm run synth
```

Defaults: Stockholm (`eu-north-1` / `eu-north-1a`), no S3 mount. Set `bucket` to your chosen bucket (for example `my-tws-files`), optional `prefix`, and explicitly opt into `s3ReadWrite`. A configured prefix must not contain shell metacharacters or spaces. Select the bucket's region when practical; cross-region S3 traffic may cost extra. SSE-KMS buckets may additionally require narrowly scoped KMS permissions and key policy access.

The AMI is resolved from Canonical's public SSM parameter at deployment time. Set `amiId` to a reviewed Ubuntu 24.04 amd64 image for repeatable rebuilds. Apt packages follow Ubuntu repositories unless pinned with `name=version`; this iteration is not a bit-for-bit reproducible image build.

## Deploy (creates billable resources)

```powershell
aws sts get-caller-identity --profile poweruser
# Inspect the existing CDKToolkit stack first. Bootstrap only if needed:
npx cdk bootstrap aws://YOUR_ACCOUNT_ID/eu-north-1 --profile poweruser
npx cdk diff --all --profile poweruser
npx cdk deploy --all --profile poweruser
```

Configure matching account/region context when bootstrapping another region. The deployment waits up to 40 minutes for provisioning to succeed. Provisioning errors after AWS CLI installation signal failure; earlier errors time out. Bootstrap logs: `/var/log/cloud-init-output.log` and `/var/log/tws-bootstrap.log`. A failed desktop deployment leaves the foundation/data disk intact.

## First login / after rebuilding

```powershell
.\scripts\workstation.ps1 session
```

In the SSM shell:

```bash
sudo passwd trader
sudo tailscale up --hostname=tws-workstation
# Follow the enrollment link, apply your tailnet access policy, then:
sudo tailscale ip -4
sudo systemctl status tws-rdp
```

Enroll only on initial setup or when reauthentication is needed; subsequent rebuilds reuse the persisted Tailscale state. On Win11 open `mstsc` and connect to the Tailscale IPv4 address with username `trader`. Use Ubuntu's Xorg session supplied by xrdp. Disconnecting preserves the session while the instance runs; logging out ends it. Only use this remote desktop session for the trader user.

TWS itself is **not silently downloaded or installed** in v0.1. Obtain the Linux installer from Interactive Brokers, run it as trader, and select a directory beneath `/home/trader` (for example `/home/trader/Jts`). Enable API socket clients, prefer localhost-only access, and keep credentials out of provisioning. For automation add a reviewed, version/checksum-pinned installer in a post-install hook, running the actual install as trader. IBKR login/MFA remains interactive. Sizing and responsiveness need validation with your TWS layout before relying on it for trading.

## Customize like a provisioning recipe

- `provision/packages.txt`: Ubuntu apt packages, one per line.
- `provision/files/rootfs/`: managed root filesystem overlay; e.g. `etc/example.conf` is copied to `/etc/example.conf`. Do not put secrets here.
- `provision/hooks/pre-install/*.sh`: before apt packages/data mount.
- `provision/hooks/post-install/*.sh`: after packages, mounts and managed files.
- `provision/hooks/first-use/*.sh`: once per persistent disk; marker written only on success.
- `provision/hooks/every-boot/*.sh`: root commands via systemd every boot, after persistent mounts.
- GUI commands: trader's `~/.config/autostart/`. Seed user settings only if absent. Use `runuser -u trader -- ...` for non-root commands, with an explicit working directory as needed.

Hooks run alphabetically and fail on nonzero exit. Write idempotent scripts. CDK uploads the provision directory as an asset; no Git credentials on the instance. Asset changes alter user data and force a desktop replacement. **Use clean `down` followed by deploy for provisioning changes**, not an in-place deployment against a running instance. A direct replacement can race attachment of the single-AZ disk or interrupt applications. Update protection and `cdk diff` review are essential; do not rename foundation constructs or change its AZ casually.

## S3

Optional rclone mount starts at desktop login at `/home/trader/S3`; IAM credentials come from the instance role. Defaults to read-only, uses full VFS cache (20 GiB target) on the persistent disk. The local rclone control API uses a generated password and binds to loopback only; this is a single-user trusted desktop. Cache limits are not hard disk quotas. S3 is not a shared POSIX filesystem; edit critical documents locally and publish them after saving. Do not edit the same object from multiple machines.

## Daily lifecycle

```powershell
.\scripts\workstation.ps1 status
.\scripts\workstation.ps1 start
# Save work and close TWS, LibreOffice and Firefox before stopping:
.\scripts\workstation.ps1 stop -ApplicationsClosed
# Clean stop and remove ONLY compute; CDK prompts for destroy confirmation:
.\scripts\workstation.ps1 down -ApplicationsClosed
# Recreate the desktop, reusing the foundation disk:
npx cdk deploy TwsDesktop --profile poweruser
```

Stop/down checks common application processes, refuses pending/errored S3 uploads, unmounts S3 and syncs before stopping. It does not force-close applications and is not an exhaustive detector for arbitrary custom apps. Do not restart writers after initiating shutdown. If checks fail, inspect SSM command output and fix the issue; there is no force-delete fallback. If already stopped, down skips remote checks. Stopping is a normal shutdown, not hibernation. No automatic daily shutdown schedule is installed in this iteration.

EBS, snapshots and CDK assets continue to cost money with compute down; public IPv4 is charged while allocated/running. Foundation deletion is intentionally protected and retains the disk; retained resources/snapshots require a separate deliberate cleanup. No resources are deleted automatically from existing S3 buckets. Test deployment/rebuild/reconnect/restore with a paper account before production use.

## References

- [CDK assets](https://docs.aws.amazon.com/cdk/v2/guide/assets.html)
- [EC2 user data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [Tailscale server setup](https://tailscale.com/docs/how-to/set-up-servers)
- [Canonical Ubuntu AMI discovery](https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/)
