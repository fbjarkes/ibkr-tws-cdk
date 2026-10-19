import {
  Stack,
  StackProps,
  CfnOutput,
  Size,
  RemovalPolicy,
  Tags,
  aws_ec2 as ec2,
  aws_iam as iam,
  aws_s3_assets as assets,
  aws_dlm as dlm,
} from "aws-cdk-lib";
import { ipv4HostCidr } from "./access";
import { Construct } from "constructs";
import { resolve } from "node:path";
export interface Config {
  region: string;
  availabilityZone: string;
  instanceType: string;
  dataGiB: number;
  rootGiB?: number;
  sshPublicKeys?: string[];
  bucket: string;
  prefix: string;
  s3ReadWrite: boolean;
  amiId: string;
  rdpCidr: string;
  s3PasswdParameter?: string;
  s3PasswdKmsKeyArn?: string;
  s3Region?: string;
}
export class Foundation extends Stack {
  readonly vpc: ec2.Vpc;
  readonly volume: ec2.Volume;
  readonly subnet: ec2.ISubnet;
  constructor(scope: Construct, id: string, props: StackProps, config: Config) {
    super(scope, id, props);
    this.vpc = new ec2.Vpc(this, "Vpc", {
      availabilityZones: [config.availabilityZone],
      natGateways: 0,
      subnetConfiguration: [
        { name: "Desktop", subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
      ],
    });
    this.subnet = this.vpc.publicSubnets[0];
    this.volume = new ec2.Volume(this, "Data", {
      availabilityZone: config.availabilityZone,
      size: Size.gibibytes(config.dataGiB),
      volumeType: ec2.EbsDeviceVolumeType.GP3,
      encrypted: true,
      removalPolicy: RemovalPolicy.RETAIN,
    });
    Tags.of(this.volume).add("TwsBackup", this.stackName);
    const backupRole = new iam.Role(this, "SnapshotRole", {
      assumedBy: new iam.ServicePrincipal("dlm.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          "service-role/AWSDataLifecycleManagerServiceRole",
        ),
      ],
    });
    new dlm.CfnLifecyclePolicy(this, "DailySnapshots", {
      executionRoleArn: backupRole.roleArn,
      state: "ENABLED",
      description: "Daily TWS data snapshots retain seven",
      policyDetails: {
        resourceTypes: ["VOLUME"],
        targetTags: [{ key: "TwsBackup", value: this.stackName }],
        schedules: [
          {
            name: "Daily",
            createRule: {
              interval: 24,
              intervalUnit: "HOURS",
              times: ["02:00"],
            },
            retainRule: { count: 7 },
            copyTags: true,
          },
        ],
      },
    });
    new CfnOutput(this, "DataVolumeId", { value: this.volume.volumeId });
  }
}
export class Desktop extends Stack {
  constructor(
    scope: Construct,
    id: string,
    props: StackProps,
    config: Config,
    foundation: Foundation,
  ) {
    super(scope, id, props);
    const sg = new ec2.SecurityGroup(this, "DesktopSecurityGroup", {
      vpc: foundation.vpc,
      description:
        "RDP and key-only SSH from one configured IPv4 host; no TWS API ingress",
      allowAllOutbound: true,
    });
    sg.addIngressRule(
      ec2.Peer.ipv4(ipv4HostCidr(config.rdpCidr)),
      ec2.Port.tcp(3389),
      "RDP from configured client IPv4",
    );
    sg.addIngressRule(
      ec2.Peer.ipv4(ipv4HostCidr(config.rdpCidr)),
      ec2.Port.tcp(22),
      "SSH from configured client IPv4",
    );
    const role = new iam.Role(this, "InstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          "AmazonSSMManagedInstanceCore",
        ),
      ],
    });
    const asset = new assets.Asset(this, "Provision", {
      path: resolve(__dirname, "../provision"),
    });
    asset.grantRead(role);
    if (config.bucket && !config.s3PasswdParameter) {
      const prefix = config.prefix
        ? config.prefix.replace(/\/$/, "") + "/"
        : "";
      role.addToPolicy(
        new iam.PolicyStatement({
          actions: ["s3:GetBucketLocation"],
          resources: [`arn:${this.partition}:s3:::${config.bucket}`],
        }),
      );
      role.addToPolicy(
        new iam.PolicyStatement({
          actions: ["s3:ListBucket"],
          resources: [`arn:${this.partition}:s3:::${config.bucket}`],
          ...(prefix
            ? {
                conditions: {
                  StringLike: { "s3:prefix": [prefix, `${prefix}*`] },
                },
              }
            : {}),
        }),
      );
      role.addToPolicy(
        new iam.PolicyStatement({
          actions: config.s3ReadWrite
            ? [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:AbortMultipartUpload",
              ]
            : ["s3:GetObject"],
          resources: [`arn:${this.partition}:s3:::${config.bucket}/${prefix}*`],
        }),
      );
    }
    if (config.bucket && config.s3PasswdParameter) {
      const parameterArn = this.formatArn({
        service: "ssm",
        resource: "parameter",
        resourceName: config.s3PasswdParameter.slice(1),
      });
      role.addToPolicy(
        new iam.PolicyStatement({
          actions: ["ssm:GetParameter"],
          resources: [parameterArn],
        }),
      );
      // SSM's core managed policy otherwise allows parameter reads on '*'.
      role.addToPolicy(
        new iam.PolicyStatement({
          effect: iam.Effect.DENY,
          actions: ["ssm:GetParameter", "ssm:GetParameters"],
          notResources: [parameterArn],
        }),
      );
      if (config.s3PasswdKmsKeyArn) {
        role.addToPolicy(
          new iam.PolicyStatement({
            actions: ["kms:Decrypt"],
            resources: [config.s3PasswdKmsKeyArn],
            conditions: {
              StringEquals: {
                "kms:ViaService": `ssm.${this.region}.${this.urlSuffix}`,
                "kms:EncryptionContext:PARAMETER_ARN": parameterArn,
              },
            },
          }),
        );
      }
    }
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ["cloudformation:SignalResource"],
        resources: [this.stackId],
      }),
    );
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      "set -euo pipefail",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update",
      "apt-get install -y curl unzip ca-certificates",
      "curl --fail --location --retry 3 https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip",
      "unzip -q /tmp/awscli.zip -d /tmp/awscli",
      "/tmp/awscli/aws/install",
      "rm -rf /tmp/awscli /tmp/awscli.zip",
    );
    const instance = new ec2.Instance(this, "Instance", {
      vpc: foundation.vpc,
      vpcSubnets: { subnets: [foundation.subnet] },
      instanceType: new ec2.InstanceType(config.instanceType),
      machineImage: config.amiId
        ? ec2.MachineImage.genericLinux({ [config.region]: config.amiId })
        : ec2.MachineImage.fromSsmParameter(
            "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id",
            { os: ec2.OperatingSystemType.LINUX },
          ),
      role,
      securityGroup: sg,
      associatePublicIpAddress: true,
      requireImdsv2: true,
      userData,
      userDataCausesReplacement: true,
      blockDevices: [
        {
          deviceName: "/dev/sda1",
          volume: ec2.BlockDeviceVolume.ebs(config.rootGiB ?? 20, {
            encrypted: true,
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            deleteOnTermination: true,
          }),
        },
      ],
    });
    const cfn = instance.node.defaultChild as ec2.CfnInstance;
    cfn.cfnOptions.creationPolicy = {
      resourceSignal: { count: 1, timeout: "PT40M" },
    };
    // Attachment cannot depend on CREATE_COMPLETE: cloud-init needs the disk before signaling readiness.
    cfn.volumes = [
      { device: "/dev/sdf", volumeId: foundation.volume.volumeId },
    ];
    const signal = `aws cloudformation signal-resource --region ${this.region} --stack-name ${this.stackName} --logical-resource-id ${cfn.logicalId} --unique-id desktop --status`;
    userData.addCommands(
      `trap 'rc=$?; if [ "$rc" -eq 0 ]; then ${signal} SUCCESS; else ${signal} FAILURE; fi' EXIT`,
      `aws s3 cp 's3://${asset.s3BucketName}/${asset.s3ObjectKey}' /tmp/provision.zip --region ${this.region}`,
      "mkdir -p /opt/tws-provision",
      "unzip -qo /tmp/provision.zip -d /opt/tws-provision",
      `export DATA_VOLUME_ID='${foundation.volume.volumeId}'`,
      `export S3_BUCKET='${config.bucket}' S3_PREFIX='${config.prefix}' S3_WRITABLE='${config.s3ReadWrite}' AWS_DEFAULT_REGION='${this.region}'`,
      `export PARAM_STORE_KEY_S3_PASSWD='${config.s3PasswdParameter || ""}' S3_REGION='${config.s3Region || config.region}'`,
      `export SSH_AUTHORIZED_KEYS_B64='${Buffer.from((config.sshPublicKeys || []).join("\n")).toString("base64")}'`,
      "bash /opt/tws-provision/bootstrap.sh",
    );
    new CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new CfnOutput(this, "SessionCommand", {
      value: `aws ssm start-session --target ${instance.instanceId} --region ${this.region} --profile poweruser`,
    });
    new CfnOutput(this, "ProvisionAssetHash", { value: asset.assetHash });
  }
}
