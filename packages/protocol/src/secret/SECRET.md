# KWatcher Secret Distribution Protocol (SECRET)

**Version:** 0
**Status:** Draft
**Last Updated:** 2026-07-22

---

## 1. Overview

### 1.1 Purpose

The SECRET protocol distributes secrets (API keys, tokens, credentials) from
one or more *secret stores* to *clients* over AMQP, end-to-end encrypted so
the broker and any other AMQP principal never see plaintext. A client
registers a public key with whatever stores are listening, then requests
secrets by identifier; a store that chooses to answer seals the secret to the
registered key and delivers it on a per-client route.

This document specifies **wire behaviour only**: everything both sides need
to interoperate. It deliberately says nothing about how either side is
implemented.

### 1.2 Design Goals

- **Broker-blind confidentiality**: secrets are encrypted before they touch
  the broker; a compromised broker or eavesdropping principal learns only
  metadata (who asked for which identifier).
- **Zero coordination**: registration is fire-and-forget broadcast; no
  handshake, no session state, no store discovery.
- **Store anonymity tolerated**: v0 clients accept answers from anyone who
  can produce an authentic sealed box for their key (see §9.1 for why this
  is a known gap, and what bounds it).
- **Policy-free**: whether a keyholder may have a secret is entirely the
  store's business. The protocol carries requests and sealed answers,
  nothing else.

### 1.3 Non-Goals

The following are explicitly out of scope for this specification:

- How a store decides to release a secret (approvals, policy, ACLs,
  human-in-the-loop).
- How or where a store persists keys and secrets, including
  encryption-at-rest.
- What triggers a client to request a secret, and its retry/timeout policy.
- Transport security between peers and the broker (broker authentication
  and TLS are deployment concerns).
- Store identity verification (v1 direction, §9.1).

### 1.4 Conventions

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be
interpreted as described in RFC 2119.

- Message bodies are JSON (UTF-8).
- Every message carries `schema_version` (integer, `0` for every message in
  this document) and `schema_name` (string), per the kwatcher schema
  convention.
- `client.v2` refers to the kwatcher client schema:
  `{ "schema_version": 2, "schema_name": "client", "id", "version", "name" }`.
- Binary values are encoded per-field as either **standard base64 with
  padding** (RFC 4648 §4) or **lowercase hex**, as specified in §5–§6.
- `||` denotes byte concatenation; `0x00` a single zero byte.

---

## 2. Roles

**Client** — holds an Ed25519 identity keypair. Registers the public key,
requests secrets, and opens sealed responses. A client is identified on the
wire by its `client.v2` object; its *key* is identified by a kid (§5.2).
The two identities are deliberately independent: the kid outlives client-id
reassignment, and a client id makes no cryptographic claim.

**Store** — listens for registrations and maintains a kid → public-key map.
Answers those requests it chooses to answer, sealed to the registered key.
A store is also an ordinary kwatcher client (it has a `client.v2` of its
own, self-asserted in responses).

Multiple stores and multiple clients MAY coexist on one broker. Nothing in
v0 partitions them; every store hears every registration and request.

---

## 3. Topology

| Message | Exchange | Routing / binding key | Direction |
|---|---|---|---|
| `secret.register` v0 | `amq.topic` | `secret.registration` | client → store(s) |
| `secret.get` v0 | `amq.topic` | `secret.request` | client → store(s) |
| `secret.response` v0 | `amq.topic` | `secret.v0.{client_id}` (from `reply_to`) | store → one client |
| `secret.reannounce.request` v0 | `amq.topic` | `secret.registration.request` | store → all clients |

`{client_id}` is the `client.id` the client presented in the `secret.get`
being answered.

- A client MUST be consuming from a queue bound to `amq.topic` with binding
  key `secret.v0.<its client.id>` before publishing its first `secret.get`,
  and MUST set the AMQP `reply_to` property of every `secret.get` to that
  binding key.
- A store MUST publish responses **only** to the route named by the
  request's `reply_to`, on the exchange the request arrived on, and MUST
  NOT deliver secret material any other way. A store MAY ignore a
  `secret.get` that carries no `reply_to`.
- Registrations and requests are broadcasts on `amq.topic`; any number of
  stores MAY be bound to them, including zero (see §8).

---

## 4. Message Flow

### 4.1 Registration (fire-and-forget)

```
Client                                  Store A         Store B
  │  secret.register ────────────────────►│───────────────►│
  │      (amq.topic/secret.registration)  │ upsert kid→key │ upsert kid→key
  │                                       │                │
  │              (no acknowledgement exists in v0)
```

### 4.2 Request / response

```
Client                                  Store A         Store B
  │  secret.get ─────────────────────────►│───────────────►│
  │      (amq.topic/secret.request)       │                │
  │                                       │ has it, allows │ doesn't / declines
  │◄── secret.response ───────────────────│                │ (silence)
  │      (amq.topic/secret.v0.{client_id}, via reply_to)
  │  open sealed box, store plaintext
```

### 4.3 Store-initiated re-registration

```
Store                                   Client 1        Client 2
  │  secret.reannounce.request ──────────►│───────────────►│
  │      (amq.topic/secret.registration.request)           │
  │◄───────────────────── secret.register │◄───────────────│
  │      (canonical route, §4.1)
```

---

## 5. Cryptography

### 5.1 Identity

A client's identity is an **Ed25519** keypair (RFC 8032). The wire
`public_key` is the 32-byte Ed25519 public key, standard base64 with
padding (always 44 characters).

### 5.2 Key id (kid)

```
kid = lowercase_hex( Blake2b-256( ed25519_public_key_bytes ) )
```

64 lowercase hex characters. The kid is fully derivable from `public_key`;
it is carried redundantly for transparency and logging. Receivers of a
`secret.register` MUST recompute the kid and reject the registration on
mismatch.

### 5.3 Scheme identifier

Every message carries a `scheme` string naming the encryption scheme in
use. Version 0 defines exactly one value:

```
kw.sealed-box.v0
```

Receivers MUST ignore messages carrying an unknown `scheme`. This field is
the landing spot for v1 scheme negotiation (§9.2).

### 5.4 Sealed box (`kw.sealed-box.v0`)

Libsodium-*style*, **not** libsodium-compatible (XChaCha20-Poly1305 and
Blake2b replace crypto_box's XSalsa20/HSalsa20). Defined entirely over
X25519 (RFC 7748), Blake2b (RFC 7693), and XChaCha20-Poly1305.

**Seal** (store side), given `plaintext`, the recipient's Ed25519 public
key, and `aad` (§5.5):

1. `recipient_x = X25519_public( recipient_ed25519_public_key )` — the
   birational Edwards→Montgomery map. If the conversion fails (non-canonical
   or small-order point), the registration is invalid and MUST be dropped.
2. Generate a fresh ephemeral X25519 keypair `(eph_sk, eph_pk)`. An
   ephemeral key MUST NOT be reused across messages.
3. `shared = X25519( eph_sk, recipient_x )`. An identity-element result
   MUST abort the seal.
4. `key = Blake2b-256( "kwatcher.secret.v0.key" || shared || eph_pk || recipient_x )`
   — 32 bytes.
5. `nonce = Blake2b-192( eph_pk || recipient_x )` — 24 bytes. (Safe as a
   deterministic nonce because `key` is unique per ephemeral keypair.)
6. `ciphertext = XChaCha20-Poly1305.encrypt( key, nonce, plaintext, aad )`
   with the 16-byte Poly1305 tag appended.

Wire form: `ephemeral_public_key` = base64(`eph_pk`, 32 bytes),
`ciphertext` = base64(ciphertext || tag).

**Open** (client side): derive `recipient_x` and the X25519 secret from the
own Ed25519 keypair, recompute steps 3–5, decrypt with the same `aad`. On
tag failure the message MUST be discarded (logging at most) — it proves
nothing except "not authentic for this key/aad".

### 5.5 AAD binding

```
aad = "kwatcher.secret.v0" || 0x00 || kid_hex || 0x00 || secret_identifier
```

where `kid_hex` is the recipient's kid (§5.2) and `secret_identifier` is
the identifier being delivered. This binds the ciphertext to both the
recipient and the secret name: a valid response for one identifier cannot
be replayed as a response for another, nor re-targeted to a different kid.

### 5.6 Zeroization (informative)

Implementations SHOULD zeroize derived keys, shared secrets, and released
plaintext when they are done with them.

---

## 6. Message Schemas

All fields are required. Unknown extra fields MUST be ignored.

### 6.1 `secret.register` v0

| Field | Type | Encoding | Description |
|---|---|---|---|
| `schema_version` | int | `0` | |
| `schema_name` | string | `"secret.register"` | |
| `scheme` | string | §5.3 | Scheme this key is registered for. |
| `public_key` | string | base64, 44 chars | Ed25519 public key. |
| `kid` | string | hex, 64 chars | §5.2; receivers MUST verify. |
| `client` | object | `client.v2` | The registering client. |

```json
{
  "schema_version": 0,
  "schema_name": "secret.register",
  "scheme": "kw.sealed-box.v0",
  "public_key": "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=",
  "kid": "26e88ab5574ac2e825b8747d05aeca98c53e4457da600e43e77164fd768d84c1",
  "client": { "schema_version": 2, "schema_name": "client",
              "id": "worker@box", "version": "1.0.0", "name": "example" }
}
```

### 6.2 `secret.get` v0

| Field | Type | Encoding | Description |
|---|---|---|---|
| `schema_version` | int | `0` | |
| `schema_name` | string | `"secret.get"` | |
| `scheme` | string | §5.3 | Scheme the response must use. |
| `kid` | string | hex, 64 chars | Key the response must be sealed to. |
| `secret_identifier` | string | UTF-8 | Opaque; namespacing is application business. |
| `client` | object | `client.v2` | `client.id` names the response route (§3). |

A `secret.get` additionally carries the transport-level AMQP `reply_to`
property, set to the client's response route `secret.v0.<client.id>` (§3).
A store MAY ignore a request without it.

### 6.3 `secret.response` v0

| Field | Type | Encoding | Description |
|---|---|---|---|
| `schema_version` | int | `0` | |
| `schema_name` | string | `"secret.response"` | |
| `scheme` | string | §5.3 | Scheme actually used. |
| `kid` | string | hex, 64 chars | Key the secret is sealed to. |
| `secret_identifier` | string | UTF-8 | Identifier being delivered. |
| `store` | object | `client.v2` | Responding store. **Self-asserted; informational only in v0.** |
| `ephemeral_public_key` | string | base64, 44 chars | §5.4 step 2. |
| `ciphertext` | string | base64 | ciphertext \|\| 16-byte tag. |

### 6.4 `secret.reannounce.request` v0

| Field | Type | Encoding | Description |
|---|---|---|---|
| `schema_version` | int | `0` | |
| `schema_name` | string | `"secret.reannounce.request"` | |

Empty payload. A store MAY broadcast it when its key map is (partially)
missing — typically after a restart. Clients answer by re-publishing
`secret.register` on the canonical route (§4.1), **not** via `reply_to`.

---

## 7. Obligations

### 7.1 Client

- MUST publish at least one `secret.register` before its first
  `secret.get`, and SHOULD re-broadcast periodically (interval unspecified):
  registration is unacknowledged and stores may start, or lose state, at
  any time.
- MUST be bound to its response route before requesting, and MUST name
  that route in each request's `reply_to` (§3).
- MUST discard a `secret.response` whose `scheme` is unknown, whose `kid`
  is not its own, or whose sealed box fails to open. Discarding MUST NOT
  affect the client's availability to later responses.
- MUST NOT trust envelope fields (`secret_identifier`, `store`) beyond what
  the AAD binding (§5.5) authenticates.
- MUST tolerate duplicate responses for one request (multiple stores MAY
  answer). Which one wins is the client's choice; the reference
  implementation keeps the last.
- SHOULD respond to `secret.reannounce.request` with a fresh registration.
- SHOULD set a broker TTL on registrations and requests so stale broadcasts
  do not queue up.

### 7.2 Store

- MUST verify `kid` against `public_key` on registration (§5.2) and drop
  mismatches.
- MUST treat registration as an **upsert keyed on kid**. Registration is
  idempotent; re-registrations are expected and harmless. (A new key is by
  construction a new kid, i.e. a new identity — there is no key rotation in
  v0, §9.6.)
- MUST seal responses only to the key registered for the request's `kid`,
  with the AAD of §5.5, and publish them only to the route named by the
  request's `reply_to`, on the exchange the request arrived on.
- MUST NOT respond at all when it lacks the secret, lacks the key, or
  declines. Silence is the only negative signal; error responses do not
  exist in v0.
- MAY broadcast `secret.reannounce.request` at any time.

---

## 8. Error Handling

There are no wire-level errors in v0.

- **No response** is indistinguishable from denial. Timeout and retry
  policy is the client's local business (a client SHOULD have one; the
  value is unspecified).
- **Unroutable broadcasts**: a broker return of `secret.register` or
  `secret.get` (mandatory-flag return) means no store is bound at all — a
  strictly stronger signal than silence. Clients MAY surface it; the
  message is lost either way.
- **Malformed messages** (bad JSON, wrong schema, failed kid check, bad
  base64): drop, optionally log. Never answer.
- **Failed opens**: drop, per §7.1.

### 8.1 Client-local behaviour (informative)

The reference client additionally lets application code register local
callback events against an in-flight request; a successful delivery drains
them onto the application's event queue. This is entirely client-internal —
nothing about it appears on the wire.

---

## 9. Known Gaps (v0) and v1 Direction

1. **No store identity.** Any AMQP principal that heard a registration can
   answer a request with a validly sealed box — a client can be handed a
   *malicious secret* by an impostor. The sealed box bounds the damage
   (confidentiality against third parties holds; the AAD prevents
   cross-identifier replay) but does not establish who answered. v1: stores
   hold their own keypair, sign responses, and clients hold a whitelist of
   trusted store kids.
2. **No scheme negotiation.** `scheme` is carried but fixed. v1:
   registration advertises supported schemes; the store picks one.
3. **No registration ack.** A client cannot know whether any store holds
   its key; it compensates by re-broadcasting. v1 may add an ack.
4. **Reannounce is broadcast-wide.** A store missing one key wakes every
   client. v1: targeted re-registration request carrying the kid(s).
5. **No store↔store gossip.** Stores converge on registrations only by
   hearing them; nothing synchronizes key maps or secrets between stores.
6. **No key rotation/revocation.** A new key is a new kid with no link to
   the old one.

---

## 10. Registries

### 10.1 Schemes

| Value | Defined in |
|---|---|
| `kw.sealed-box.v0` | §5.4 |

### 10.2 Schemas

| `schema_name` | `schema_version` | Defined in |
|---|---|---|
| `secret.register` | 0 | §6.1 |
| `secret.get` | 0 | §6.2 |
| `secret.response` | 0 | §6.3 |
| `secret.reannounce.request` | 0 | §6.4 |

### 10.3 Routing keys

| Exchange | Key | Defined in |
|---|---|---|
| `amq.topic` | `secret.registration` | §3 |
| `amq.topic` | `secret.request` | §3 |
| `amq.topic` | `secret.v0.{client_id}` | §3 |
| `amq.topic` | `secret.registration.request` | §3 |

---

## Appendix A. Test Vectors

Mirrored by the unit tests in `v0/crypto.zig`; keep the two in sync.

### A.1 Identity / kid

```
ed25519 seed        = 0x42 repeated 32 times
public_key (base64) = IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=
kid                 = 26e88ab5574ac2e825b8747d05aeca98c53e4457da600e43e77164fd768d84c1
```

### A.2 Sealed box

Sealing `"hunter2"` for `secret_identifier` `"api/example"` to the A.1
identity, with the ephemeral X25519 keypair derived from seed `0x24`
repeated 32 times:

```
recipient_x (hex)          = cc4f2cdb695dd766f34118eb67b98652fed1d8bc49c330b119bbfa8a64989378
ephemeral_public_key (b64) = BLzS4NAPLM5f6PHGwvvsXAf6VuOqXIilaJl12Is/zgU=
shared (hex)               = 1be8f74fef2795ec2990902b180e9e906ed810692b466b95395ee5df96e4125f
key (hex)                  = f72e7f6418f38a47ac78b7669fa51a9826abcaa09d0a45a77baeaffa98379b93
nonce (hex)                = d6f90da40bb095c1dcc825be074598067a90647680293a1f
aad                        = "kwatcher.secret.v0" 0x00 kid_hex 0x00 "api/example"
ciphertext||tag (b64)      = lle80YDrmro7AfekjEiDRwdlTNgwpa8=
```
