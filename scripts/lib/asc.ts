#!/usr/bin/env bun
/**
 * A thin App Store Connect API client: a signed token, a fetch wrapper, and
 * pagination.
 *
 * Separate from `asc-push.ts` because the interesting part of that script is
 * which resources it touches and in what order, and none of that is legible
 * with request plumbing interleaved. Nothing here knows what an app is.
 *
 * Credentials come from `apple-project.json`, which is gitignored and names the
 * key; the key itself lives outside the repo at `appStoreConnect.privateKeyPath`.
 */

import { createSign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BASE = "https://api.appstoreconnect.apple.com";

interface Credentials {
  issuerId: string;
  keyId: string;
  privateKey: string;
}

/** Reads the identifiers from `apple-project.json` and the key from disk. */
export function credentials(): Credentials {
  const config = JSON.parse(readFileSync("apple-project.json", "utf8"));
  const asc = config.appStoreConnect;
  const keyId: string = process.env.ASC_KEY_ID ?? asc.activeKeyId;

  const expand = (p: string) => (p.startsWith("~") ? join(homedir(), p.slice(1)) : p);
  // Two directories because the .p8 downloads exactly once and is then kept in
  // both places; whichever survives a machine rebuild is the one that works.
  const dirs = [asc.privateKeyPath, asc.backupPath].filter(Boolean).map(expand);
  const path = dirs.map((d) => join(d, `AuthKey_${keyId}.p8`)).find(existsSync);
  if (!path) throw new Error(`AuthKey_${keyId}.p8 not found in ${dirs.join(" or ")}`);

  return { issuerId: asc.issuerId, keyId, privateKey: readFileSync(path, "utf8") };
}

const b64url = (b: Buffer | string) =>
  Buffer.from(b).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/**
 * An ES256 JWT, twenty minutes long — Apple's maximum, and rejected outright if
 * you ask for more.
 *
 * `ieee-p1363` is not a detail to skip. Node signs ECDSA as DER by default and
 * JWS requires the raw r‖s pair; a DER signature is well-formed, verifiable by
 * OpenSSL, and answered by App Store Connect with a bare 401 that says nothing
 * about encoding.
 */
export function token({ issuerId, keyId, privateKey }: Credentials): string {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = { iss: issuerId, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" };
  const signing = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signature = createSign("SHA256")
    .update(signing)
    .sign({ key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${signing}.${b64url(signature)}`;
}

/**
 * What comes back over the wire. Apple's attribute sets differ per resource
 * type and change between API versions, so the honest type for a bag of them
 * is JSON — not `any`, which would let a typo through, and not `unknown`,
 * which would make every read a cast.
 */
export type Json = string | number | boolean | null | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export interface Resource {
  type: string;
  id: string;
  attributes?: JsonObject;
  relationships?: JsonObject;
}

export class Client {
  private jwt: string;
  private issued = 0;
  private creds: Credentials;

  constructor(creds = credentials()) {
    this.creds = creds;
    this.jwt = token(creds);
    this.issued = Date.now();
  }

  /** Re-signs after fifteen minutes. A full push outlives one token. */
  private auth(): string {
    if (Date.now() - this.issued > 15 * 60_000) {
      this.jwt = token(this.creds);
      this.issued = Date.now();
    }
    return `Bearer ${this.jwt}`;
  }

  async request(method: string, path: string, body?: JsonObject): Promise<any> {
    const headers = body
      ? { authorization: this.auth(), "content-type": "application/json" }
      : { authorization: this.auth() };

    const res = await fetch(path.startsWith("http") ? path : `${BASE}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });

    if (res.status === 204) return null;
    const text = await res.text();
    if (!res.ok) {
      // Apple's errors are the useful part of this API. `detail` names the
      // field and the reason — "Attribute 'subtitle' is too long" — and losing
      // it to a bare status code turns a two-character overrun into an
      // afternoon.
      let detail = text.slice(0, 400);
      try {
        const errors = JSON.parse(text).errors ?? [];
        detail = errors.map((e: any) => `${e.title}: ${e.detail ?? ""}`).join("; ") || detail;
      } catch {}
      throw new Error(`${method} ${path} → ${res.status} ${detail}`);
    }
    return text ? JSON.parse(text) : null;
  }

  get = (path: string) => this.request("GET", path);
  post = (path: string, body: JsonObject) => this.request("POST", path, body);
  patch = (path: string, body: JsonObject) => this.request("PATCH", path, body);
  delete = (path: string) => this.request("DELETE", path);

  /** Follows `links.next` to the end. Apple pages at 50 and never says so. */
  async all(path: string): Promise<Resource[]> {
    const out: Resource[] = [];
    let next: string | undefined = path;
    while (next) {
      const page = await this.get(next);
      out.push(...(page.data ?? []));
      next = page.links?.next;
    }
    return out;
  }
}

/** A relationship as Apple wants it written: one linkage object per name. */
type Relationships = Record<string, { data: { type: string; id: string } }>;

/**
 * The request half of a resource. `id` is present on an update and absent on a
 * create; `relationships` only when the call is establishing one.
 */
interface RequestData {
  type: string;
  id?: string;
  attributes: JsonObject;
  relationships?: Relationships;
}

/** The shape every create and update takes, so call sites stay one line. */
export const body = (
  type: string,
  attributes: JsonObject,
  relationships?: Relationships,
  id?: string,
) => {
  const data: RequestData = { type, attributes };
  if (id) data.id = id;
  if (relationships) data.relationships = relationships;
  return { data };
};
