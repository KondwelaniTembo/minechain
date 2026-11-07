# MineChain API

The REST API used by the MineChain Android app. During development it runs locally at
`http://localhost:3000`. Hosting on Render is planned.

Every example on this page uses obviously fake values: IDs such as
`3f2b6c1e-0000-4000-8000-000000000001`, and tokens that contain the words `FAKE-PAYLOAD`
and `FAKE-SIGNATURE`. None of them is a real identifier, password or token.

## Endpoints

| Method | Path | Purpose | Login needed |
|---|---|---|---|
| `GET` | [`/health`](#get-health) | Is the API up, and can it reach the database? | No |
| `POST` | [`/auth/register`](#post-authregister) | Request an account (FR-12) | No |
| `POST` | [`/auth/login`](#post-authlogin) | Log in and receive a token (FR-06) | No |
| `GET` | [`/auth/me`](#get-authme) | The logged-in user's own account | Yes |
| `PUT` | [`/auth/me/public-key`](#put-authmepublic-key) | Register this phone's device key (FR-02) | Yes, miner, transporter or buyer |
| `GET` | [`/admin/users`](#get-adminusers) | List accounts by status (FR-10, FR-12) | Yes, admin only |
| `POST` | [`/admin/users/{id}/approve`](#post-adminusersidapprove) | Approve an account request (FR-12) | Yes, admin only |
| `POST` | [`/admin/users/{id}/reject`](#post-adminusersidreject) | Reject an account request, with a reason (FR-12) | Yes, admin only |
| `POST` | [`/admin/users/{id}/suspend`](#post-adminusersidsuspend) | Suspend an active account, with a reason (FR-10) | Yes, admin only |
| `POST` | [`/admin/users/{id}/reactivate`](#post-adminusersidreactivate) | Reactivate a suspended account (FR-10) | Yes, admin only |
| `POST` | [`/admin/users/{id}/reset-key`](#post-adminusersidreset-key) | Remove a suspended account's device key, for a lost phone | Yes, admin only |

## Conventions

- Requests and responses are JSON. Send `Content-Type: application/json` with a body.
- A request body may be at most 100 kB.
- Field names are camelCase. Times are ISO 8601 in UTC, for example `2026-11-05T09:00:00.000Z`.
- Every response carries security headers (Helmet), for example
  `X-Content-Type-Options: nosniff`.
- Responses that contain a token or personal details carry `Cache-Control: no-store`, so
  no phone, browser or proxy keeps a copy.

## Error format

Every error, whatever its cause, has the same shape:

```json
{
  "error": {
    "code": "USERNAME_TAKEN",
    "message": "That username is already taken. Please choose another."
  }
}
```

- `code` is stable and meant for the app's logic. It never changes for a given situation.
- `message` is plain language and can be shown to the user.
- `details` is added only for `VALIDATION_FAILED` and `WEAK_PASSWORD`, as a list naming each
  problem:

  ```json
  {
    "error": {
      "code": "VALIDATION_FAILED",
      "message": "Some fields are missing or invalid.",
      "details": [
        { "field": "role", "message": "must be miner, transporter or buyer" },
        { "field": "status", "message": "is not allowed" }
      ]
    }
  }
  ```

  A problem with the request as a whole (for example no body at all) uses `"field": "body"`.

The values that were sent are never echoed back in an error, so a password can never
appear in a response.

**Errors any endpoint can return:**

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `INVALID_JSON` | The body is not valid JSON | Request body is not valid JSON |
| 400 | `VALIDATION_FAILED` | A field is missing, invalid, or not allowed | Some fields are missing or invalid. |
| 404 | `NOT_FOUND` | No such route | Route not found |
| 413 | `PAYLOAD_TOO_LARGE` | The body is over 100 kB | Request body is too large |
| 429 | `TOO_MANY_REQUESTS` | A rate limit was reached (see below) | Depends on the limit |
| 500 | `INTERNAL_ERROR` | An unexpected server fault. Details are written to the server log, never sent | Something went wrong |

## Authentication

Protected endpoints need the token from [`POST /auth/login`](#post-authlogin) in the
`Authorization` header:

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

- **Only the header is read.** A token in the URL (for example `?access_token=…`) is ignored,
  because URLs are written to server logs, proxy logs and browser history.
- The scheme word `Bearer` may be in any letter case.
- **A token lasts at most 60 minutes** (the `expiresIn` value at login, in seconds). After
  that, log in again. There are no refresh tokens.
- **The account is checked on every request.** A token stops working at once if the account
  is suspended, set back to pending, rejected, deleted, or given a different role, even
  before the token expires.
- Store the token in the phone's secure storage, never in plain preferences or logs.

**Token errors:**

| Status | Code | When | Message |
|---|---|---|---|
| 401 | `TOKEN_MISSING` | No `Authorization` header, another scheme (such as `Basic`), or `Bearer` with nothing after it | Please log in to continue. |
| 401 | `TOKEN_INVALID` | The token is malformed, forged, tampered with, or no longer matches the account (the user no longer exists, or the role changed). Logging in again fixes it | Your session is not valid. Please log in again. |
| 401 | `TOKEN_EXPIRED` | The token is older than its lifetime. Ask for the password again | Your session has expired. Please log in again. |
| 403 | `ACCOUNT_PENDING` | The account is waiting for approval | Your account is waiting for approval by an administrator. |
| 403 | `ACCOUNT_SUSPENDED` | The account has been suspended | Your account has been suspended. Please contact an administrator. |
| 403 | `ACCOUNT_REJECTED` | The account request was not approved | Your account request was not approved. Please contact an administrator. |
| 403 | `ACCOUNT_NOT_ACTIVE` | Any other status that is not active (a fallback) | Your account is not active. Please contact an administrator. |
| 403 | `FORBIDDEN` | Logged in and active, but this role may not use this endpoint (see [Roles and access](#roles-and-access)) | You do not have permission to do this. |

**401 vs 403:** a 401 means the credentials don't work, and logging in again may help. A 403
means the server knows exactly who you are, and the account is not allowed in. Logging in
again would give the same answer.

Every 401 from a protected endpoint carries a `WWW-Authenticate` header (RFC 6750):

| Situation | Header |
|---|---|
| No usable credentials sent (`TOKEN_MISSING`) | `WWW-Authenticate: Bearer realm="minechain"` |
| A token was sent but refused (`TOKEN_INVALID`, `TOKEN_EXPIRED`) | `WWW-Authenticate: Bearer realm="minechain", error="invalid_token"` |

A 403 has no `WWW-Authenticate` header, because the credentials themselves were fine.

## Rate limits

| Endpoint | Limit | Counted per | What counts |
|---|---|---|---|
| `POST /auth/register` | 30 per hour | client IP | every request, including invalid ones |
| `POST /auth/login` | 100 per 15 minutes | client IP | every request, including invalid ones |
| `POST /auth/login` | 10 per 15 minutes | username (any letter case or surrounding spaces) | failed attempts only (401 and 403). Successful logins are not counted |

The per-IP limits are high on purpose. Zambian mobile networks use carrier-grade NAT, so a
whole mining site can share one public IP address. The per-username limit is what stops
password guessing against one account. It applies the same way to usernames that do not
exist, so it does not reveal which accounts are real.

**Headers.** Rate-limited responses carry the IETF draft-8 `RateLimit` and `RateLimit-Policy`
headers, one entry per limiter:

```
RateLimit: "100-in-15min"; r=97; t=812
RateLimit-Policy: "100-in-15min"; q=100; w=900; pk=:ZmFrZWZha2VmYWtl:
```

| Part | Meaning |
|---|---|
| `"100-in-15min"` | Which limit this entry describes |
| `r` | Requests remaining in the current window |
| `t` | Seconds until the window resets |
| `q` | The limit (quota) |
| `w` | The window length in seconds |
| `pk` | A short fingerprint of what is being counted. It is a hash, never the IP address or username itself |

`POST /auth/login` passes two limiters, so its responses carry two entries in each header
(`"100-in-15min"` for the IP and `"10-in-15min"` for the username).

When a limit is reached, the response is **429 `TOO_MANY_REQUESTS`** in the normal error
format, with a **`Retry-After`** header giving the seconds to wait:

```
HTTP/1.1 429 Too Many Requests
Retry-After: 812
```

```json
{
  "error": {
    "code": "TOO_MANY_REQUESTS",
    "message": "Too many failed login attempts for this username. Please try again in 15 minutes."
  }
}
```

## Roles and access

Every account has exactly one of five roles: `miner`, `transporter`, `buyer`, `officer`
(regulatory officer) or `admin` (system administrator). Each protected endpoint states which
roles may use it, and the server checks this on every request:

1. **The token is checked** (`requireAuth`). If it fails, the answer is 401, or 403 for an
   account that is not active.
2. **The role is checked** (`requireRole`). The role is read from the database at that
   moment, never from the token. A role outside the endpoint's list gets **403
   `FORBIDDEN`**, "You do not have permission to do this." The message never says which
   roles would be allowed.

If an administrator changes someone's role, that person's existing token stops working at
once (401 `TOKEN_INVALID`). After logging in again, the new role applies.

**Planned access by role.** The [`/admin/users`](#admin-account-management) endpoints are
the first to use role checks. This matrix shows which role uses, or is planned to use,
which part of the system, based on FR-06 (each role sees only its own
modules) and the requirements listed. It will be updated as each endpoint is built, and
the endpoint sections below remain the source of truth for what exists.

| Module (requirement) | Miner | Transporter | Buyer | Officer | Admin | Status |
|---|:-:|:-:|:-:|:-:|:-:|---|
| Own account: `GET /auth/me` | ✓ | ✓ | ✓ | ✓ | ✓ | **Built** |
| Register a device key (FR-02): `PUT /auth/me/public-key` | ✓ | ✓ | ✓ | | | **Built** |
| Register a consignment at extraction (FR-01, FR-02) | ✓ | | | | | Planned |
| Record a handoff to a transporter (FR-02, FR-03) | | ✓ | | | | Planned |
| Record a purchase (FR-02, FR-03) | | | ✓ | | | Planned |
| Sync signed work recorded offline (FR-07) | ✓ | ✓ | ✓ | | | Planned |
| Verify a consignment by QR code (FR-04) | | ✓ | ✓ | ✓ | | Planned |
| View a consignment's full custody chain (FR-04, FR-05) | | | ✓ | ✓ | | Planned |
| Signed provenance certificate (FR-16) | | | ✓ | | | Planned |
| Transaction reports and spreadsheet export (FR-09) | | | ✓ | ✓ | ✓ read-only | Planned |
| Review anomaly alerts, with case notes (FR-08) | | | | ✓ | | Planned |
| Download audit trails (FR-13) | | | | ✓ | | Planned |
| Approve or reject account requests (FR-12): `/admin/users/{id}/approve`, `/reject` | | | | | ✓ | **Built** |
| List accounts; suspend and reactivate them (FR-10): `GET /admin/users`, `/admin/users/{id}/suspend`, `/reactivate` | | | | | ✓ | **Built** |
| Reset a lost phone's device key (FR-10, [signing spec](signing-spec.md) section 2): `/admin/users/{id}/reset-key` | | | | | ✓ | **Built** |
| Create officer and admin accounts; change role (FR-10) | | | | | ✓ | Planned |
| Manage licensed GPS extraction zones (FR-11) | | | | | ✓ | Planned |
| Monitor system health: API errors, blockchain sync failures, database capacity (System Administrator use case) | | | | | ✓ | Planned |
| Trigger a manual re-synchronisation (System Administrator use case) | | | | | ✓ | Planned |

The administrator's rows follow the System Administrator use case: managing accounts and
zones, checking and downloading reports, monitoring the system's health, and starting a
manual re-synchronisation.

Three things to note about the matrix:

- **Each role records only its own custody step.** A transporter cannot register a
  consignment, and a miner cannot record a purchase, so a signed step always comes from the
  kind of actor the contract stage expects.
- **The administrator runs the system, but does not record custody steps or review
  alerts.** The administrator may check and download reports, read-only, but cannot create,
  change or sign anything in the custody chain, and cannot close an alert. A manual
  re-synchronisation only retries sending steps that are already recorded and approved; it
  never creates or changes one. Keeping these apart means one stolen administrator account
  cannot also fake supply chain records or clear anomaly alerts.
- **Officers have read access across all actors and zones,** which is what regulatory review
  needs. They do not record custody steps either.

---

## GET /health

Reports whether the API is running and can reach its database. Hosting health checks and
uptime monitors use it.

| | |
|---|---|
| **Login needed** | No |
| **Rate limits** | None |
| **Request body** | None |

**200 OK**: the API is up and the database answered.

```json
{ "status": "ok", "database": "up" }
```

**503 Service Unavailable**: the API is up, but the database did not answer. The reason is
written to the server log, never sent.

```json
{ "status": "error", "database": "down" }
```

This endpoint returns only up or down: no versions, configuration or error details.

---

## POST /auth/register

Requests a new account (FR-12). The account starts as **pending**: it cannot log in until an
administrator approves it. Officer and administrator accounts cannot be requested here; an
administrator creates them (FR-10).

| | |
|---|---|
| **Login needed** | No |
| **Rate limits** | 30 per IP per hour |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `username` | string | yes | Surrounding spaces are trimmed. 3–32 characters from `A–Z a–z 0–9 _ . -`. Unique, ignoring letter case |
| `fullName` | string | yes | Surrounding spaces are trimmed. 1–100 characters |
| `password` | string | yes | Not trimmed. Must meet the password policy below |
| `role` | string | yes | `miner`, `transporter` or `buyer` |
| `licenceNumber` | string | no | Surrounding spaces are trimmed. 1–50 characters |

Any other field (for example `status` or `id`) is refused with `VALIDATION_FAILED`.

**Password policy.** 12 to 128 characters; spaces are allowed, and a few words make a good
password, for example `gold river kasempa`. There are no rules about digits or symbols. A
password is refused if it:

- is one character repeated;
- contains the username;
- is on a list of common passwords.

```json
{
  "username": "mutale_banda",
  "fullName": "Mutale Banda",
  "password": "gold river kasempa",
  "role": "miner",
  "licenceNumber": "ZM-ASM-0042"
}
```

**201 Created**

```json
{
  "user": {
    "id": "3f2b6c1e-0000-4000-8000-000000000001",
    "username": "mutale_banda",
    "fullName": "Mutale Banda",
    "licenceNumber": "ZM-ASM-0042",
    "role": "miner",
    "status": "pending",
    "createdAt": "2026-11-05T09:00:00.000Z",
    "publicKeyFingerprint": null
  },
  "message": "Your account has been requested. An administrator must approve it before you can log in."
}
```

The response never contains the password, its hash, or the user's on-chain reference.

**Errors**

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | A field is missing or invalid, the role is not `miner`, `transporter` or `buyer`, or an unknown field was sent. `details` names each field | Some fields are missing or invalid. |
| 400 | `WEAK_PASSWORD` | The password breaks the policy. `details` lists each problem (see below) | Choose a stronger password. |
| 400 | `INVALID_JSON` | The body is not valid JSON | Request body is not valid JSON |
| 409 | `USERNAME_TAKEN` | The username exists already, in any letter case | That username is already taken. Please choose another. |
| 413 | `PAYLOAD_TOO_LARGE` | The body is over 100 kB | Request body is too large |
| 429 | `TOO_MANY_REQUESTS` | 30 requests from this IP in the last hour | Too many registration attempts from this network. Please try again later. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

`WEAK_PASSWORD` details have `"field": "password"`, a `code` and a `message`:

| Detail code | Message |
|---|---|
| `PASSWORD_TOO_SHORT` | Use at least 12 characters. A few words with spaces works well. |
| `PASSWORD_TOO_LONG` | Use at most 128 characters. |
| `PASSWORD_REPEATED` | Do not use one character repeated. |
| `PASSWORD_CONTAINS_USERNAME` | Do not include your username in your password. |
| `PASSWORD_TOO_COMMON` | This password is too common. Choose something less easy to guess. |

```json
{
  "error": {
    "code": "WEAK_PASSWORD",
    "message": "Choose a stronger password.",
    "details": [
      { "field": "password", "code": "PASSWORD_TOO_SHORT", "message": "Use at least 12 characters. A few words with spaces works well." }
    ]
  }
}
```

---

## POST /auth/login

Checks a username and password, and returns a token for an active account (FR-06).

| | |
|---|---|
| **Login needed** | No |
| **Rate limits** | 100 per IP per 15 minutes, and 10 failed attempts per username per 15 minutes |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `username` | string | yes | Surrounding spaces are trimmed. 1–32 characters. Letter case does not matter |
| `password` | string | yes | Not trimmed. 1–1024 characters. The password policy is not applied at login |

Any other field is refused with `VALIDATION_FAILED`.

```json
{ "username": "mutale_banda", "password": "gold river kasempa" }
```

**200 OK**, with `Cache-Control: no-store`

```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE",
  "tokenType": "Bearer",
  "expiresIn": 3600,
  "user": {
    "id": "3f2b6c1e-0000-4000-8000-000000000001",
    "username": "mutale_banda",
    "fullName": "Mutale Banda",
    "licenceNumber": "ZM-ASM-0042",
    "role": "miner",
    "status": "active",
    "createdAt": "2026-11-05T09:00:00.000Z",
    "publicKeyFingerprint": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}
```

`expiresIn` is in seconds and is never more than 3600. The token's payload contains only
the user id, role, issue and expiry times, issuer and audience. It is signed, not encrypted,
so it never contains a name or other personal data.

**Errors**

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | A field is missing, empty, too long (password over 1024 characters), or not allowed | Some fields are missing or invalid. |
| 400 | `INVALID_JSON` | The body is not valid JSON | Request body is not valid JSON |
| 401 | `INVALID_CREDENTIALS` | The username does not exist, **or** the password is wrong. The two are deliberately identical, and take about the same time, so nobody can find out which usernames exist | Username or password is incorrect. |
| 403 | `ACCOUNT_PENDING` | Correct password, but the account is waiting for approval | Your account is waiting for approval by an administrator. |
| 403 | `ACCOUNT_SUSPENDED` | Correct password, but the account is suspended | Your account has been suspended. Please contact an administrator. |
| 403 | `ACCOUNT_REJECTED` | Correct password, but the account request was not approved | Your account request was not approved. Please contact an administrator. |
| 403 | `ACCOUNT_NOT_ACTIVE` | Correct password, any other status that is not active (a fallback) | Your account is not active. Please contact an administrator. |
| 413 | `PAYLOAD_TOO_LARGE` | The body is over 100 kB | Request body is too large |
| 429 | `TOO_MANY_REQUESTS` | 100 requests from this IP in 15 minutes | Too many login attempts from this network. Please try again later. |
| 429 | `TOO_MANY_REQUESTS` | 10 failed attempts for this username in 15 minutes | Too many failed login attempts for this username. Please try again in 15 minutes. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

An account's status (the 403s) is revealed only after the correct password. A pending
account with a wrong password gets the same 401 as anyone else.

---

## GET /auth/me

Returns the logged-in user's own account, as the database has it now.

| | |
|---|---|
| **Login needed** | Yes: `Authorization: Bearer <token>` |
| **Rate limits** | None yet |
| **Request body** | None |

```
GET /auth/me
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

**200 OK**, with `Cache-Control: no-store`

```json
{
  "user": {
    "id": "3f2b6c1e-0000-4000-8000-000000000001",
    "username": "mutale_banda",
    "fullName": "Mutale Banda",
    "licenceNumber": "ZM-ASM-0042",
    "role": "miner",
    "status": "active",
    "createdAt": "2026-11-05T09:00:00.000Z",
    "publicKeyFingerprint": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}
```

**Errors**

| Status | Code | When | Message |
|---|---|---|---|
| 401 | `TOKEN_MISSING` | No usable `Authorization: Bearer` header | Please log in to continue. |
| 401 | `TOKEN_INVALID` | Malformed, forged or tampered token, or the user no longer exists, or the role changed | Your session is not valid. Please log in again. |
| 401 | `TOKEN_EXPIRED` | The token's lifetime has passed | Your session has expired. Please log in again. |
| 403 | `ACCOUNT_PENDING` | The account was set back to pending after the token was issued | Your account is waiting for approval by an administrator. |
| 403 | `ACCOUNT_SUSPENDED` | The account was suspended after the token was issued | Your account has been suspended. Please contact an administrator. |
| 403 | `ACCOUNT_REJECTED` | The account was rejected after the token was issued | Your account request was not approved. Please contact an administrator. |
| 403 | `ACCOUNT_NOT_ACTIVE` | Any other status that is not active (a fallback) | Your account is not active. Please contact an administrator. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

See [Authentication](#authentication) for the `WWW-Authenticate` header on each 401.

**`publicKeyFingerprint`** appears on the user in every response that returns one
(`/auth/register`, `/auth/login`, `/auth/me`, `/auth/me/public-key`). It is the lower-case
hex SHA-256 of the account's registered device key (SPKI DER), 64 characters, or `null` when
no key is registered. The key itself is never returned. The app compares it with the
fingerprint of the key in its own Keystore:

| `publicKeyFingerprint` | What the app does |
|---|---|
| `null` | Register this phone's key with [`PUT /auth/me/public-key`](#put-authmepublic-key) |
| the same as this phone's key | Nothing: this phone is the registered device |
| different | Do not sign. This phone is not the registered device: ask an administrator to reset the key |

The fingerprint in the examples is a placeholder pattern, not a real key's.

---

## PUT /auth/me/public-key

Registers the device key of the logged-in user (FR-02, [signing spec](signing-spec.md)
section 2). The app creates a P-256 key pair in the Android Keystore after the first login
on a phone, and sends the public half here. The private key never leaves the phone. The
server later checks every signed custody step against this key.

| | |
|---|---|
| **Login needed** | Yes: miner, transporter or buyer (the roles that sign custody steps). Officers and administrators get 403 `FORBIDDEN` |
| **Rate limits** | None yet. To be reviewed in the security review on Saturday 14 November |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `publicKey` | string | yes | The key as SubjectPublicKeyInfo DER, in standard base64 with padding: exactly 91 bytes, which is 124 characters. P-256 only, uncompressed. Not trimmed: spaces, line breaks, base64url and PEM text are refused |

Any other field (for example `userId`) is refused with `VALIDATION_FAILED`. The key is always
registered on the logged-in account, never one named in the body.

```
PUT /auth/me/public-key
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
Content-Type: application/json
```

```json
{ "publicKey": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFA==" }
```

(The start of that value is how every P-256 key begins in base64; the rest is a placeholder.)

**200 OK**, with `Cache-Control: no-store`, both the first time and when the same key is sent
again:

```json
{
  "user": {
    "id": "3f2b6c1e-0000-4000-8000-000000000001",
    "username": "mutale_banda",
    "fullName": "Mutale Banda",
    "licenceNumber": "ZM-ASM-0042",
    "role": "miner",
    "status": "active",
    "createdAt": "2026-11-05T09:00:00.000Z",
    "publicKeyFingerprint": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}
```

- **A key is registered once.** Sending the **same** key again is safe and changes nothing:
  a phone on a weak network may never receive the first answer and retry. Sending a
  **different** key is refused. Replacing a key needs an administrator
  ([reset-key](#post-adminusersidreset-key)), so a stolen password alone cannot install
  someone else's key.
- **One key, one account.** A key already registered to another account is refused.
- The first registration is recorded in the audit log as `user.key_register`, with the key's
  fingerprint, never the key itself. A repeat records nothing.

**Errors**

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | `publicKey` is missing, empty, not a string or over 200 characters, or another field was sent | Some fields are missing or invalid. |
| 400 | `INVALID_PUBLIC_KEY` | Not strict standard base64, not 91 bytes, not a P-256 key, a point not on the curve, or not in canonical SPKI DER form | The device key must be a P-256 public key in SPKI DER form, sent as standard base64. |
| 401 | `TOKEN_MISSING`, `TOKEN_INVALID`, `TOKEN_EXPIRED` | See [Authentication](#authentication) | |
| 403 | `ACCOUNT_PENDING`, `ACCOUNT_SUSPENDED`, `ACCOUNT_REJECTED` | The account is not active | See [Authentication](#authentication) |
| 403 | `FORBIDDEN` | An officer or administrator account, which never signs custody steps | You do not have permission to do this. |
| 409 | `PUBLIC_KEY_ALREADY_REGISTERED` | This account already has a **different** key | This account already has a different device key. Ask an administrator to reset it. |
| 409 | `PUBLIC_KEY_IN_USE` | Another account already has this key | This device key is already registered to another account. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

Every response, errors included, carries `Cache-Control: no-store`.

---

## Admin account management

Six endpoints let an administrator review account requests (FR-12), suspend or reactivate
accounts (FR-10), and remove a lost phone's device key. Creating officer and administrator
accounts and changing a role are planned for a later step.

**Rules shared by all six:**

- **Admin only.** Every request needs a token, and the account must be an active `admin`.
  Anyone else gets 401 or 403 (see [Roles and access](#roles-and-access)). This applies to
  every path under `/admin/users`, including paths that do not exist: a non-admin gets 403,
  not 404, so the paths cannot be discovered.
- **No caching.** Every response, errors included, carries `Cache-Control: no-store`.
- **Rate limits:** none yet. To be reviewed in the security review on Saturday 14 November.
- **One action per endpoint.** Each action moves an account from one status to another, and
  only from that status:

  | Action | From | To | Body | Roles it applies to |
  |---|---|---|---|---|
  | Approve | `pending` | `active` | none, or `{}` | `miner`, `transporter`, `buyer` |
  | Reject | `pending` | `rejected` | `{ "reason": "…" }` | `miner`, `transporter`, `buyer` |
  | Suspend | `active` | `suspended` | `{ "reason": "…" }` | All roles, with two extra rules for administrators (below) |
  | Reactivate | `suspended` | `active` | none, or `{}` | All roles |
  | Reset key | `suspended` | `suspended` (the device key is removed; the status does not change) | `{ "reason": "…" }` | Accounts with a device key: `miner`, `transporter`, `buyer` |

  **Rejected is final.** No action leads out of `rejected`. The person must request a new
  account under a different username.
- **Two administrators acting at once:** the check and the change happen in one database
  step, so only one of them succeeds. The other gets 409 `INVALID_STATUS_TRANSITION`.
- **Every change is recorded** in the audit log, in the same database transaction, with the
  administrator as the actor, their IP address, and `{ from, to }` plus the reason where
  there is one. The actions are `user.approve`, `user.reject`, `user.suspend` and
  `user.reactivate`. A key reset is recorded as `user.key_reset` with `{ reason,
  keyFingerprint }`, naming the removed key by fingerprint.
- **`{id}`** is the user's id, a UUID. Upper- or lower-case letters are both accepted.

**Reasons.** Reject, suspend and reset key need a reason: 3 to 500 characters after surrounding spaces
are trimmed. Line breaks are allowed. **A reason is kept permanently** in the append-only
audit log, where it can never be edited or removed. Keep it short and factual, for example
`Licence number could not be verified`, and do not add personal details that are not needed.
The reason is shown to administrators only, never to the account's owner.

**The admin view of a user.** All six endpoints return users in this form. Unlike
[`GET /auth/me`](#get-authme), it includes the status reason and the approval. It never
contains the password hash, the on-chain reference or the device key itself, only the key's
fingerprint.

| Field | Meaning |
|---|---|
| `id` | The user's id |
| `username`, `fullName`, `licenceNumber`, `role`, `status` | As in `/auth/me` |
| `statusReason` | Why the account is suspended or rejected; `null` otherwise |
| `approvedBy` | The id of the administrator who approved the account; `null` if never approved through the API (for example a seeded account) |
| `approvedAt` | When it was approved; `null` with `approvedBy` |
| `createdAt`, `updatedAt` | When the account was requested, and when it last changed |
| `publicKeyFingerprint` | The SHA-256 fingerprint of the registered device key, as in [`/auth/me`](#get-authme); `null` when there is none. Lets an administrator see whether there is a key to reset, and compare it with the one the user's phone shows |

**Errors these endpoints can return**, on top of the [token errors](#authentication):

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | `{id}` is not a UUID; a reason is missing, too short or too long; a body or query has a field it should not | Some fields are missing or invalid. |
| 403 | `FORBIDDEN` | Logged in and active, but not an administrator | You do not have permission to do this. |
| 403 | `CANNOT_SUSPEND_SELF` | An administrator tried to suspend their own account | You cannot suspend your own account. |
| 404 | `USER_NOT_FOUND` | No user has this id | No user has this id. |
| 409 | `INVALID_STATUS_TRANSITION` | The account is not in the status this action starts from (for example approving an active account, resetting the key of an account that is not suspended, or anything on a rejected one) | Only a pending account can be approved. This account is active. (The wording names the action and the actual status.) |
| 409 | `ROLE_NOT_APPROVABLE` | Approve or reject on an officer or administrator account. Those are created by an administrator, never requested | Officer and administrator accounts are created by an administrator, not approved or rejected. |
| 409 | `LAST_ACTIVE_ADMIN` | Suspending this administrator would leave no other active administrator | At least one other active administrator must remain, so this account cannot be suspended. |
| 409 | `NO_PUBLIC_KEY` | Reset key on a suspended account that has no device key | This account has no device key to reset. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

---

## GET /admin/users

Lists accounts with one status, oldest request first. With no query it lists the first page
of pending requests: the queue an administrator works through (FR-12).

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |
| **Request body** | None |

**Query parameters**

| Parameter | Default | Rules |
|---|---|---|
| `status` | `pending` | `pending`, `active`, `suspended` or `rejected` |
| `limit` | `20` | Whole number, 1 to 100 |
| `offset` | `0` | Whole number, 0 to 10 000: how many matching accounts to skip |

`limit` and `offset` must be plain digits: `1e2`, `0x10` or ` 5 ` are refused, not
converted. Any other parameter is refused with `VALIDATION_FAILED`.

```
GET /admin/users?status=pending&limit=20&offset=0
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

**200 OK**

```json
{
  "users": [
    {
      "id": "3f2b6c1e-0000-4000-8000-000000000001",
      "username": "mutale_banda",
      "fullName": "Mutale Banda",
      "licenceNumber": "ZM-ASM-0042",
      "role": "miner",
      "status": "pending",
      "statusReason": null,
      "approvedBy": null,
      "approvedAt": null,
      "createdAt": "2026-11-05T09:00:00.000Z",
      "updatedAt": "2026-11-05T09:00:00.000Z",
      "publicKeyFingerprint": null
    }
  ],
  "total": 1,
  "limit": 20,
  "offset": 0
}
```

`total` counts every account with that status, not only this page, so the app can show
"page 1 of 3". An `offset` past the end gives an empty `users` list with the real `total`.

---

## POST /admin/users/{id}/approve

Approves a pending request from a miner, transporter or buyer (FR-12). The account becomes
`active` and can log in. `approvedBy` and `approvedAt` are set.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |
| **Request body** | None, or `{}`. Any field is refused |

```
POST /admin/users/3f2b6c1e-0000-4000-8000-000000000001/approve
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

**200 OK**

```json
{
  "user": {
    "id": "3f2b6c1e-0000-4000-8000-000000000001",
    "username": "mutale_banda",
    "fullName": "Mutale Banda",
    "licenceNumber": "ZM-ASM-0042",
    "role": "miner",
    "status": "active",
    "statusReason": null,
    "approvedBy": "3f2b6c1e-0000-4000-8000-0000000000ad",
    "approvedAt": "2026-11-06T10:15:00.000Z",
    "createdAt": "2026-11-05T09:00:00.000Z",
    "updatedAt": "2026-11-06T10:15:00.000Z",
    "publicKeyFingerprint": null
  }
}
```

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `USER_NOT_FOUND`,
`INVALID_STATUS_TRANSITION` (the account is not pending) and `ROLE_NOT_APPROVABLE` (an
officer or administrator account). See [the shared table](#admin-account-management).

---

## POST /admin/users/{id}/reject

Rejects a pending request from a miner, transporter or buyer (FR-12). The account becomes
`rejected` for good, and the reason is stored in `statusReason`.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `reason` | string | yes | Surrounding spaces are trimmed. 3–500 characters. Kept permanently in the audit log |

```json
{ "reason": "Licence number could not be verified" }
```

**200 OK**: the user in the admin view, with `"status": "rejected"` and
`"statusReason": "Licence number could not be verified"`.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `USER_NOT_FOUND`,
`INVALID_STATUS_TRANSITION` (the account is not pending) and `ROLE_NOT_APPROVABLE`.

---

## POST /admin/users/{id}/suspend

Suspends an active account of any role (FR-10). The account's next request is refused with
403 `ACCOUNT_SUSPENDED`, even with a token that has not expired, because every request
checks the account in the database.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |

**Request body**: `reason`, with the same rules as for
[reject](#post-adminusersidreject).

```json
{ "reason": "Lost device reported" }
```

**200 OK**: the user in the admin view, with `"status": "suspended"` and
`"statusReason": "Lost device reported"`.

**Two rules for administrator accounts:**

- An administrator cannot suspend themselves: 403 `CANNOT_SUSPEND_SELF`.
- At least one other active administrator must remain: 409 `LAST_ACTIVE_ADMIN`. This also
  holds when two administrators try to suspend each other at the same moment. The second
  request waits for the first and is then refused, so the system can never be left
  without an administrator.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `CANNOT_SUSPEND_SELF`, `USER_NOT_FOUND`,
`INVALID_STATUS_TRANSITION` (the account is not active) and `LAST_ACTIVE_ADMIN`.

---

## POST /admin/users/{id}/reactivate

Makes a suspended account active again (FR-10). `statusReason` is cleared; the suspension's
reason remains in the audit log. `approvedBy` and `approvedAt` keep the original approval.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |
| **Request body** | None, or `{}`. Any field is refused |

```
POST /admin/users/3f2b6c1e-0000-4000-8000-000000000001/reactivate
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

**200 OK**: the user in the admin view, with `"status": "active"` and
`"statusReason": null`. The user's existing token works again at once.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `USER_NOT_FOUND` and
`INVALID_STATUS_TRANSITION` (the account is not suspended; a rejected account can never be
reactivated).

---

## POST /admin/users/{id}/reset-key

Removes the device key of a **suspended** account, so the user can register the key of a
new phone. It is the third of the five steps for a lost, stolen or replaced phone
([signing spec](signing-spec.md), section 2):

1. The user tells an administrator.
2. The administrator [suspends](#post-adminusersidsuspend) the account. Any token on the
   lost phone stops working at once.
3. The administrator resets the key with this endpoint.
4. The administrator [reactivates](#post-adminusersidreactivate) the account, once the real
   user is confirmed (ideally with the new phone in hand).
5. The user logs in on the new phone, which registers its key with
   [`PUT /auth/me/public-key`](#put-authmepublic-key).

The account must be suspended first. If a key could be reset on an active account, whoever
logged in next would register the new key, possibly the person holding the lost phone.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |

**Request body**: `reason`, with the same rules as for [reject](#post-adminusersidreject).

```
POST /admin/users/3f2b6c1e-0000-4000-8000-000000000001/reset-key
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
Content-Type: application/json
```

```json
{ "reason": "Lost device reported" }
```

**200 OK**: the user in the admin view, still `"status": "suspended"` with its suspension
reason, and now `"publicKeyFingerprint": null`.

- **The status does not change.** Reactivating is a separate, deliberate step.
- **Steps already recorded keep verifying.** Each stored step keeps a copy of the key that
  signed it, so a reset never invalidates past evidence. Records signed by the lost phone
  that arrive after the reset no longer verify, which is the purpose of the reset.
- **Recorded** in the audit log as `user.key_reset`, with the reason and the removed key's
  fingerprint (never the key itself).

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `USER_NOT_FOUND`,
`INVALID_STATUS_TRANSITION` (the account is not suspended: "Only a suspended account can
have its device key reset. This account is active.") and `NO_PUBLIC_KEY` (the account has
no key, so nothing was changed). See [the shared table](#admin-account-management).
