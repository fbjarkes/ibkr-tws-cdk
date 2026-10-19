import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ipv4HostCidr, loadRdpCidr } from "../lib/access";
import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";
import { Foundation, Desktop, Config } from "../lib/stacks";

test("only one valid IPv4 host is accepted", () => {
  assert.equal(ipv4HostCidr(" 203.0.113.10 "), "203.0.113.10/32");
  assert.equal(ipv4HostCidr("203.0.113.10/32"), "203.0.113.10/32");
  for (const value of [
    undefined,
    "",
    "0.0.0.0",
    "0.0.0.0/0",
    "203.0.113.0/24",
    "::1",
    "999.1.1.1",
    "1.2.3.4,5.6.7.8",
    "$(command)",
  ]) {
    assert.throws(() => ipv4HostCidr(value), /IP_ADDRESS/);
  }
});

test("editing .env is picked up without cached shell values", () => {
  const directory = mkdtempSync(join(tmpdir(), "tws-env-"));
  const file = join(directory, ".env");
  try {
    const environment = { IP_ADDRESS: "192.0.2.1" };
    assert.equal(loadRdpCidr(file, environment), "192.0.2.1/32");
    writeFileSync(file, 'IP_ADDRESS="203.0.113.10" # first address\n');
    assert.equal(loadRdpCidr(file, environment), "203.0.113.10/32");
    writeFileSync(file, "IP_ADDRESS=198.51.100.20\n");
    assert.equal(loadRdpCidr(file, environment), "198.51.100.20/32");
    writeFileSync(file, "IP_ADDRESS=\n");
    assert.throws(() => loadRdpCidr(file, environment), /IP_ADDRESS/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("an IP-only change modifies only security-group rules, not EC2 or user data", () => {
  function synth(rdpCidr: string) {
    const app = new App();
    const config: Config = {
      region: "eu-north-1",
      availabilityZone: "eu-north-1a",
      instanceType: "m7i.xlarge",
      dataGiB: 50,
      bucket: "",
      prefix: "",
      s3ReadWrite: false,
      amiId: "ami-0123456789abcdef0",
      rdpCidr,
    };
    const env = { account: "123456789012", region: config.region };
    const foundation = new Foundation(app, "TwsFoundation", { env }, config);
    const desktop = new Desktop(app, "TwsDesktop", { env }, config, foundation);
    return {
      base: Template.fromStack(foundation).toJSON(),
      desktop: Template.fromStack(desktop).toJSON(),
    };
  }
  const before = synth("203.0.113.10/32");
  const after = synth("198.51.100.20/32");
  assert.deepEqual(before.base, after.base);
  const changed = Object.keys(before.desktop.Resources).filter(
    (id) =>
      JSON.stringify(before.desktop.Resources[id]) !==
      JSON.stringify(after.desktop.Resources[id]),
  );
  assert.equal(changed.length, 1);
  assert.equal(
    before.desktop.Resources[changed[0]].Type,
    "AWS::EC2::SecurityGroup",
  );
  const normalized = structuredClone(after.desktop);
  normalized.Resources[changed[0]].Properties.SecurityGroupIngress =
    before.desktop.Resources[changed[0]].Properties.SecurityGroupIngress;
  assert.deepEqual(before.desktop, normalized);
});
