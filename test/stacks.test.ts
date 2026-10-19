import { test } from "node:test";
import { App } from "aws-cdk-lib";
import { Template, Match } from "aws-cdk-lib/assertions";
import { Foundation, Desktop, Config } from "../lib/stacks";
test("persistent disk, IP-restricted RDP ingress and least-privilege defaults", () => {
  const app = new App();
  const config: Config = {
    region: "eu-north-1",
    availabilityZone: "eu-north-1a",
    instanceType: "m7i.xlarge",
    dataGiB: 50,
    bucket: "example-tws",
    prefix: "reports",
    s3ReadWrite: false,
    amiId: "ami-0123456789abcdef0",
    rdpCidr: "203.0.113.10/32",
  };
  const env = { account: "123456789012", region: config.region };
  const foundation = new Foundation(app, "TwsFoundation", { env }, config);
  const desktop = new Desktop(app, "TwsDesktop", { env }, config, foundation);
  const base = Template.fromStack(foundation);
  base.hasResource("AWS::EC2::Volume", {
    DeletionPolicy: "Retain",
    UpdateReplacePolicy: "Retain",
    Properties: Match.objectLike({ Encrypted: true, Size: 50 }),
  });
  base.resourceCountIs("AWS::EC2::NatGateway", 0);
  base.resourceCountIs("AWS::DLM::LifecyclePolicy", 1);
  const template = Template.fromStack(desktop);
  template.hasResourceProperties("AWS::EC2::SecurityGroup", {
    SecurityGroupIngress: [
      {
        CidrIp: "203.0.113.10/32",
        Description: "RDP from configured client IPv4",
        FromPort: 3389,
        IpProtocol: "tcp",
        ToPort: 3389,
      },
      {
        CidrIp: "203.0.113.10/32",
        Description: "SSH from configured client IPv4",
        FromPort: 22,
        IpProtocol: "tcp",
        ToPort: 22,
      },
    ],
  });
  template.hasResourceProperties("AWS::EC2::Instance", {
    BlockDeviceMappings: Match.arrayWith([
      Match.objectLike({
        Ebs: Match.objectLike({ VolumeSize: 20, Encrypted: true }),
      }),
    ]),
    Volumes: Match.arrayWith([Match.objectLike({ Device: "/dev/sdf" })]),
  });
  template.hasResourceProperties("AWS::EC2::LaunchTemplate", {
    LaunchTemplateData: Match.objectLike({
      MetadataOptions: { HttpTokens: "required" },
    }),
  });
  template.hasResource("AWS::EC2::Instance", {
    CreationPolicy: { ResourceSignal: { Count: 1, Timeout: "PT40M" } },
  });
  const serialized = JSON.stringify(template.toJSON());
  if (serialized.includes("s3:PutObject"))
    throw new Error("Read-only bucket must not grant writes");
});
