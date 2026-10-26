import { existsSync, readFileSync } from "node:fs";
import { isIPv4 } from "node:net";
import { resolve } from "node:path";
import { homedir } from "node:os";
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

/** Only public OpenSSH keys, without identifying comments or authorized_keys options. */
export function parseSshPublicKeys(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"))
    .map((line) => {
      const [algorithm, encoded] = line.split(/\s+/);
      if (
        !/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))$/.test(
          algorithm,
        ) ||
        !encoded ||
        !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)
      )
        throw new Error(
          "SSH_PUBLIC_KEYS_FILE must contain only OpenSSH public keys, never private keys",
        );
      const blob = Buffer.from(encoded, "base64");
      if (blob.toString("base64") !== encoded || blob.length < 8)
        throw new Error("Invalid SSH public key encoding");
      const length = blob.readUInt32BE(0);
      if (
        length > blob.length - 4 ||
        blob.subarray(4, 4 + length).toString() !== algorithm ||
        blob.length <= 4 + length
      )
        throw new Error("Invalid SSH public key payload");
      return algorithm + " " + encoded;
    });
}

export function loadSshPublicKeys(environment: NodeJS.ProcessEnv): string[] {
  const file = environment.SSH_PUBLIC_KEYS_FILE?.trim();
  if (!file) return [];
  const expanded =
    file.startsWith("~/") || file.startsWith("~\\")
      ? resolve(homedir(), file.slice(2))
      : resolve(file);
  const keys = parseSshPublicKeys(readFileSync(expanded, "utf8"));
  if (!keys.length)
    throw new Error("SSH_PUBLIC_KEYS_FILE contains no public keys");
  return [...new Set(keys)];
}
