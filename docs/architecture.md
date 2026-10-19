# Workstation architecture

This diagram describes the current CDK source and default configuration, not a verified live deployment. AWS resource names are used; diagram boxes are schematic, not official AWS icons.

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

## Ownership and lifecycle

| Layer | Managed resources | Behavior |
| --- | --- | --- |
| `TwsFoundation` | VPC, subnet, routing, Internet Gateway, persistent EBS volume, DLM policy and DLM role | Kept during desktop teardown; stack termination protection enabled; data volume has retention policies. |
| `TwsDesktop` | EC2, root EBS disk, security group, instance role/profile, data-volume attachment | Cleanly stop, destroy and recreate; existing data disk is reattached in the same AZ. |
| CDK bootstrap | Deployment roles and S3 assets bucket | Created separately by `cdk bootstrap`, retained independently of desktop stack. |
| Existing S3 data bucket | Optional user-selected bucket/prefix | Not created or deleted by this project. Bucket region may differ from the illustrated region. |

## Access and provisioning details

- RDP binds to the Tailscale IPv4 address. Public TCP 3389, SSH and the TWS API are not opened. Configure Tailscale grants to restrict permitted devices/users.
- Tailscale attempts a direct encrypted connection; it can fall back to an external relay. The EC2 host still uses the Internet Gateway for internet connectivity. Its public IPv4 address is not an Elastic IP and can change after stop/start.
- Systems Manager works through outbound connections; no inbound management port is required. No VPC endpoints, VPN gateway, NAT gateway or load balancer is configured.
- S3 and Systems Manager are regional services outside the VPC. EBS volumes are AZ resources attached to EC2, not resources inside its subnet. IAM is account-scoped.
- Cloud-init downloads a CDK S3 asset, installs packages, copies managed files and executes custom hooks. Systemd runs the every-boot hooks. Asset access uses the instance role, not stored AWS access keys.
- Localhost-only TWS API access is the recommended application setting; it must be enabled/configured in TWS. No separate IB Gateway process is provisioned.
- S3 mounting is disabled in the default configuration. When enabled, rclone uses the instance role and caches files on persistent EBS. S3 is not the home directory or a native shared filesystem.
- TWS installation, initial Tailscale enrollment, desktop password setup and IBKR login remain first-use operations. Rebuilds retain data and Tailscale state, not running application sessions.
