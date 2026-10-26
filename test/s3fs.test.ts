import { test } from "node:test";
import assert from "node:assert/strict";
import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";
import { Foundation, Desktop, Config } from "../lib/stacks";

test("role mode grants full object access only under the selected prefix", () => {
  const app = new App();
  const config: Config = {
    region: "eu-north-1",
    availabilityZone: "eu-north-1a",
    instanceType: "m7i.xlarge",
    dataGiB: 50,
    bucket: "example-tws",
    prefix: "watchlists",
    s3ReadWrite: true,
    amiId: "ami-0123456789abcdef0",
    rdpCidr: "203.0.113.10/32",
  };
  const env = { account: "123456789012", region: config.region };
  const base = new Foundation(app, "TwsFoundation", { env }, config);
  const template = Template.fromStack(
    new Desktop(app, "TwsDesktop", { env }, config, base),
  ).toJSON();
  const statements = Object.values<any>(template.Resources)
    .filter((r) => r.Type === "AWS::IAM::Policy")
    .flatMap((r) => r.Properties.PolicyDocument.Statement);
  const full = statements.filter(
    (s) => s.Effect === "Allow" && s.Action === "s3:*",
  );
  assert.equal(full.length, 1);
  assert.deepEqual(full[0].Resource, {
    "Fn::Join": [
      "",
      ["arn:", { Ref: "AWS::Partition" }, ":s3:::example-tws/watchlists/*"],
    ],
  });
  const listing = statements.find((s) =>
    [s.Action].flat().includes("s3:ListBucket"),
  );
  assert.deepEqual(listing.Condition, {
    StringLike: { "s3:prefix": ["watchlists/", "watchlists/*"] },
  });
  assert.ok(
    !statements.some(
      (s) =>
        s.Effect === "Allow" &&
        [s.Action].flat().includes("ssm:GetParameter"),
    ),
  );
});
