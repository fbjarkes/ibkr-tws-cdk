import { existsSync, readFileSync } from "node:fs";
import { isIPv4 } from "node:net";
import { resolve } from "node:path";
import { parseEnv } from "node:util";

/** Exactly one IPv4 host; never widen a typo into a subnet or world-open rule. */
export function ipv4HostCidr(value: string | undefined): string {
  const input = value?.trim() ?? "";
  const address = input.endsWith("/32") ? input.slice(0, -3) : input;
  if (!isIPv4(address) || address === "0.0.0.0") {
    throw new Error(
      "IP_ADDRESS must be one IPv4 address, optionally ending in /32. Set your public client IPv4 in .env; broader CIDRs and IPv6 are not supported.",
    );
  }
  return address + "/32";
}

/** Re-read .env on every synthesis. File value wins over an inherited shell value. */
export function loadRdpCidr(
  file = resolve(".env"),
  environment: NodeJS.ProcessEnv = process.env,
): string {
  return ipv4HostCidr(loadLocalEnvironment(file, environment).IP_ADDRESS);
}

export function loadLocalEnvironment(
  file = resolve(".env"),
  environment: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const values = existsSync(file) ? parseEnv(readFileSync(file, "utf8")) : {};
  return { ...environment, ...values };
}

export function s3ParameterSettings(environment: NodeJS.ProcessEnv) {
  const s3PasswdParameter = environment.PARAM_STORE_KEY_S3_PASSWD?.trim() || "";
  const s3PasswdKmsKeyArn = environment.S3_PASSWD_KMS_KEY_ARN?.trim() || "";
  if (
    s3PasswdParameter &&
    !/^\/[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/.test(s3PasswdParameter)
  ) {
    throw new Error(
      "PARAM_STORE_KEY_S3_PASSWD must be an absolute parameter name, without wildcards or a version suffix",
    );
  }
  if (
    s3PasswdKmsKeyArn &&
    (!s3PasswdParameter ||
      !/^arn:aws(?:-us-gov|-cn)?:kms:[a-z0-9-]+:[0-9]{12}:key\/[a-f0-9-]+$/.test(
        s3PasswdKmsKeyArn,
      ))
  ) {
    throw new Error(
      "S3_PASSWD_KMS_KEY_ARN requires a parameter name and a valid customer-managed KMS key ARN",
    );
  }
  return { s3PasswdParameter, s3PasswdKmsKeyArn };
}
