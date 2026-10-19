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
  const values = existsSync(file) ? parseEnv(readFileSync(file, "utf8")) : {};
  return ipv4HostCidr(values.IP_ADDRESS ?? environment.IP_ADDRESS);
}
