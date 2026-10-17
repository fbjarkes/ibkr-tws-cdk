import { App } from "aws-cdk-lib";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { Foundation, Desktop, Config } from "../lib/stacks";
const app = new App();
const base = JSON.parse(
  readFileSync(resolve("config/workstation.json"), "utf8"),
);
const local = existsSync(resolve("config/local.json"))
  ? JSON.parse(readFileSync(resolve("config/local.json"), "utf8"))
  : {};
const config: Config = { ...base, ...local };
if (!config.availabilityZone.startsWith(config.region))
  throw new Error("Availability zone must match region");
if (
  !/^[a-z0-9.-]*$/.test(config.bucket) ||
  config.prefix.startsWith("/") ||
  !/^[A-Za-z0-9_./=-]*$/.test(config.prefix)
)
  throw new Error("Invalid bucket/prefix");
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: config.region };
// The deployment deliberately uses one configured AZ; no discovery lookup is needed.
if (env.account) {
  app.node.setContext(
    `availability-zones:account=${env.account}:region=${config.region}`,
    [config.availabilityZone],
  );
}
const foundation = new Foundation(
  app,
  "TwsFoundation",
  { env, terminationProtection: true },
  config,
);
new Desktop(app, "TwsDesktop", { env }, config, foundation);
