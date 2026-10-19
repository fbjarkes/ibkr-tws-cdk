import { test } from "node:test";
import assert from "node:assert/strict";
import { parseSshPublicKeys, loadSshPublicKeys } from "../lib/access";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function publicKey() {
  const algorithm = Buffer.from("ssh-ed25519");
  const header = Buffer.alloc(4);
  header.writeUInt32BE(algorithm.length);
  const size = Buffer.alloc(4);
  size.writeUInt32BE(32);
  return (
    "ssh-ed25519 " +
    Buffer.concat([header, algorithm, size, Buffer.alloc(32, 7)]).toString(
      "base64",
    )
  );
}

test("SSH key configuration accepts public keys and removes personal comments", () => {
  const key = publicKey();
  assert.deepEqual(
    parseSshPublicKeys("# client keys\n" + key + " person@example.invalid\n"),
    [key],
  );
  for (const invalid of [
    "-----BEGIN OPENSSH PRIVATE KEY-----",
    "command=evil " + key,
    "ssh-ed25519 not-base64!",
    "ssh-ed25519 QUJDRA==",
  ])
    assert.throws(() => parseSshPublicKeys(invalid));
});

test("public-key file is optional, supports multiple clients, and rejects empty files", () => {
  assert.deepEqual(loadSshPublicKeys({}), []);
  const directory = mkdtempSync(join(tmpdir(), "tws-public-keys-"));
  const file = join(directory, "clients.pub");
  try {
    writeFileSync(
      file,
      publicKey() + " first-client\n" + publicKey() + " duplicate-client\n",
    );
    assert.deepEqual(loadSshPublicKeys({ SSH_PUBLIC_KEYS_FILE: file }), [
      publicKey(),
    ]);
    writeFileSync(file, "# no keys\n");
    assert.throws(
      () => loadSshPublicKeys({ SSH_PUBLIC_KEYS_FILE: file }),
      /no public keys/,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
