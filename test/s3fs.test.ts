import { test } from "node:test";
import assert from "node:assert/strict";
import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";
import { Foundation, Desktop, Config } from "../lib/stacks";
import { s3ParameterSettings } from "../lib/access";

test("secret configuration accepts references only", () => {
  assert.deepEqual(s3ParameterSettings({}), {
    s3PasswdParameter: "",
    s3PasswdKmsKeyArn: "",
  });
  assert.equal(
    s3ParameterSettings({ PARAM_STORE_KEY_S3_PASSWD: "/tws/s3fs/passwd" })
      .s3PasswdParameter,
    "/tws/s3fs/passwd",
  );
  for (const value of ["/tws/*", "KEY:SECRET", "/tws/passwd:1", "$(command)"]) {
    assert.throws(() =>
      s3ParameterSettings({ PARAM_STORE_KEY_S3_PASSWD: value }),
    );
  }
  assert.throws(() =>
    s3ParameterSettings({
      S3_PASSWD_KMS_KEY_ARN:
        "arn:aws:kms:eu-north-1:123456789012:key/11111111-1111-1111-1111-111111111111",
    }),
  );
});

test("password-file mode scopes parameter and KMS access without resolving the secret", () => {
  const app = new App();
  const config: Config = {
    region: "eu-north-1",
    availabilityZone: "eu-north-1a",
    instanceType: "m7i.xlarge",
    dataGiB: 100,
    bucket: "example-tws",
    prefix: "watchlists",
    s3Region: "eu-north-1",
    s3ReadWrite: true,
    amiId: "ami-0123456789abcdef0",
    rdpCidr: "203.0.113.10/32",
    s3PasswdParameter: "/tws/s3fs/passwd",
    s3PasswdKmsKeyArn:
      "arn:aws:kms:eu-north-1:123456789012:key/11111111-1111-1111-1111-111111111111",
  };
  const env = { account: "123456789012", region: config.region };
  const base = new Foundation(app, "TwsFoundation", { env }, config);
  const template = Template.fromStack(
    new Desktop(app, "TwsDesktop", { env }, config, base),
  ).toJSON();
  const statements = Object.values(template.Resources)
    .filter((resource: any) => resource.Type === "AWS::IAM::Policy")
    .flatMap((resource: any) => resource.Properties.PolicyDocument.Statement);
  const text = JSON.stringify(template);
  const allow = statements.find(
    (statement: any) =>
      statement.Effect === "Allow" && statement.Action === "ssm:GetParameter",
  );
  assert.ok(
    allow &&
      JSON.stringify(allow.Resource).includes("parameter/tws/s3fs/passwd"),
  );
  const deny = statements.find(
    (statement: any) => statement.Effect === "Deny" && statement.NotResource,
  );
  assert.ok(deny.Action.includes("ssm:GetParameters"));
  assert.deepEqual(deny.NotResource, allow.Resource);
  const decrypt = statements.find(
    (statement: any) => statement.Action === "kms:Decrypt",
  );
  assert.equal(decrypt.Resource, config.s3PasswdKmsKeyArn);
  assert.equal(
    JSON.stringify(decrypt.Condition.StringEquals["kms:ViaService"]).includes(
      "ssm.eu-north-1",
    ),
    true,
  );
  assert.deepEqual(
    decrypt.Condition.StringEquals["kms:EncryptionContext:PARAMETER_ARN"],
    allow.Resource,
  );
  assert.ok(!text.includes("ssm:PutParameter"));
  assert.ok(!text.includes("{{resolve:ssm-secure:"));
  // Password mode must not accidentally grant the EC2 role access to the data bucket.
  assert.ok(!text.includes("s3:PutObject"));
});
