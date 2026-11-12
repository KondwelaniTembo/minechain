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
| `POST` | [`/auth/activate`](#post-authactivate) | Activate an officer or administrator account with its activation code, choose a password, and receive a token (FR-10) | No |
| `GET` | [`/auth/me`](#get-authme) | The logged-in user's own account | Yes |
| `PUT` | [`/auth/me/public-key`](#put-authmepublic-key) | Register this phone's device key (FR-02) | Yes, miner, transporter or buyer |
| `POST` | [`/auth/me/password`](#post-authmepassword) | Change your own password; every other session ends (FR-06) | Yes, any role |
| `GET` | [`/admin/users`](#get-adminusers) | List accounts by status (FR-10, FR-12) | Yes, admin only |
| `POST` | [`/admin/users`](#post-adminusers) | Create an officer or administrator account, with a one-time activation code (FR-10) | Yes, admin only |
| `POST` | [`/admin/users/{id}/approve`](#post-adminusersidapprove) | Approve an account request (FR-12) | Yes, admin only |
| `POST` | [`/admin/users/{id}/reject`](#post-adminusersidreject) | Reject an account request, with a reason (FR-12) | Yes, admin only |
| `POST` | [`/admin/users/{id}/suspend`](#post-adminusersidsuspend) | Suspend an active account, with a reason (FR-10) | Yes, admin only |
| `POST` | [`/admin/users/{id}/reactivate`](#post-adminusersidreactivate) | Reactivate a suspended account (FR-10) | Yes, admin only |
| `POST` | [`/admin/users/{id}/reset-key`](#post-adminusersidreset-key) | Remove a suspended account's device key, for a lost phone | Yes, admin only |
| `POST` | [`/admin/users/{id}/activation-code`](#post-adminusersidactivation-code) | Issue a new activation code for an invited account; the old one stops working (FR-10) | Yes, admin only |
| `GET` | [`/admin/zones`](#get-adminzones) | List licensed GPS zones by status (FR-11) | Yes, admin only |
| `POST` | [`/admin/zones`](#post-adminzones) | Create a licensed GPS zone (FR-11) | Yes, admin only |
| `POST` | [`/admin/zones/{id}/rename`](#post-adminzonesidrename) | Rename a zone (FR-11) | Yes, admin only |
| `POST` | [`/admin/zones/{id}/deactivate`](#post-adminzonesiddeactivate) | Deactivate an active zone, with a reason (FR-11) | Yes, admin only |
| `POST` | [`/admin/zones/{id}/reactivate`](#post-adminzonesidreactivate) | Reactivate an inactive zone (FR-11) | Yes, admin only |
| `GET` | [`/admin/anchoring`](#get-adminanchoring) | Anchoring status: the worker, what is waiting, stuck or failed, and a list of problems (FR-03) | Yes, admin only |
| `POST` | [`/admin/anchoring/run`](#post-adminanchoringrun) | Run one anchoring tick now (FR-03) | Yes, admin only |
| `POST` | [`/admin/anchoring/steps/{id}/retry`](#post-adminanchoringstepsidretry) | Send a failed step back to the anchoring queue, with a reason (FR-03) | Yes, admin only |
| `GET` | [`/reports/transactions`](#get-reportstransactions) | Download custody steps as a spreadsheet (CSV), filtered (FR-09) | Yes, officer, buyer (own purchases only) or admin |
| `GET` | [`/reports/audit-trail`](#get-reportsaudit-trail) | Download the audit trail of one consignment or one actor as CSV (FR-13) | Yes, officer only |
| `POST` | [`/sync/steps`](#post-syncsteps) | Upload signed custody steps from the phone's offline queue (FR-03, FR-07) | Yes, miner, transporter or buyer |

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
- `details` is added only for `VALIDATION_FAILED`, `WEAK_PASSWORD`,
  `CURRENT_PASSWORD_INCORRECT` and `PASSWORD_UNCHANGED`, as a list naming each problem:

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
- **A password change ends every other session.** A token issued before the account's last
  password change gets 401 `TOKEN_INVALID`, the same answer as for a deleted account, so the
  answer does not say that the password was changed. The token returned by the change itself
  keeps working (see [`POST /auth/me/password`](#post-authmepassword)).
- Store the token in the phone's secure storage, never in plain preferences or logs.

**Token errors:**

| Status | Code | When | Message |
|---|---|---|---|
| 401 | `TOKEN_MISSING` | No `Authorization` header, another scheme (such as `Basic`), or `Bearer` with nothing after it | Please log in to continue. |
| 401 | `TOKEN_INVALID` | The token is malformed, forged, tampered with, or no longer matches the account (the user no longer exists, the role changed, or the token was issued before the account's last password change). Logging in again fixes it | Your session is not valid. Please log in again. |
| 401 | `TOKEN_EXPIRED` | The token is older than its lifetime. Ask for the password again | Your session has expired. Please log in again. |
| 403 | `ACCOUNT_PENDING` | The account is waiting for approval | Your account is waiting for approval by an administrator. |
| 403 | `ACCOUNT_SUSPENDED` | The account has been suspended | Your account has been suspended. Please contact an administrator. |
| 403 | `ACCOUNT_REJECTED` | The account request was not approved | Your account request was not approved. Please contact an administrator. |
| 403 | `ACCOUNT_NOT_ACTIVATED` | The account was created by an administrator and has not been activated yet. An invited account has no password and cannot log in, so the app does not normally meet this code (login answers `INVALID_CREDENTIALS` first) | Your account has not been activated yet. Use the activation code from your administrator. |
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
| `POST /auth/activate` | 30 per 15 minutes | client IP | every request, including invalid ones |
| `POST /auth/me/password` | 10 per 15 minutes | logged-in user | failed attempts only (every error after the token check, including `VALIDATION_FAILED`). Successful changes are not counted. A request refused for its token never reaches the limiter |

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
| Change own password (FR-06): `POST /auth/me/password` | ✓ | ✓ | ✓ | ✓ | ✓ | **Built** |
| Activate an account an administrator created (FR-10): `POST /auth/activate`, no login | | | | ✓ | ✓ | **Built** |
| Register a device key (FR-02): `PUT /auth/me/public-key` | ✓ | ✓ | ✓ | | | **Built** |
| Register a consignment at extraction (FR-01, FR-02) | ✓ | | | | | Planned |
| Record a handoff to a transporter (FR-02, FR-03) | | ✓ | | | | Planned |
| Record a purchase (FR-02, FR-03) | | | ✓ | | | Planned |
| Sync signed work recorded offline (FR-03, FR-07): `POST /sync/steps` | ✓ | ✓ | ✓ | | | **Built** |
| Verify a consignment by QR code (FR-04) | | ✓ | ✓ | ✓ | | Planned |
| View a consignment's full custody chain (FR-04, FR-05) | | | ✓ | ✓ | | Planned |
| Signed provenance certificate (FR-16) | | | ✓ | | | Planned |
| Transaction reports and spreadsheet export (FR-09): `GET /reports/transactions` (a buyer sees only consignments they bought) | | | ✓ | ✓ | ✓ read-only | **Built** |
| Review anomaly alerts, with case notes (FR-08) | | | | ✓ | | Planned |
| Download audit trails (FR-13): `GET /reports/audit-trail` | | | | ✓ | | **Built** |
| Approve or reject account requests (FR-12): `/admin/users/{id}/approve`, `/reject` | | | | | ✓ | **Built** |
| List accounts; suspend and reactivate them (FR-10): `GET /admin/users`, `/admin/users/{id}/suspend`, `/reactivate` | | | | | ✓ | **Built** |
| Reset a lost phone's device key (FR-10, [signing spec](signing-spec.md) section 2): `/admin/users/{id}/reset-key` | | | | | ✓ | **Built** |
| Create officer and admin accounts, and reissue their activation codes (FR-10): `POST /admin/users`, `/admin/users/{id}/activation-code` | | | | | ✓ | **Built** |
| Change an account's role; delete an account with no history (FR-10) | | | | | ✓ | Planned |
| Manage licensed GPS extraction zones (FR-11): `/admin/zones` | | | | | ✓ | **Built** |
| Monitor blockchain anchoring: the worker, stuck and failed steps, a list of problems (System Administrator use case): `GET /admin/anchoring` | | | | | ✓ | **Built** |
| Trigger a manual re-synchronisation (System Administrator use case): `POST /admin/anchoring/run`, `/admin/anchoring/steps/{id}/retry` | | | | | ✓ | **Built** |
| Monitor the rest of system health: API errors, database capacity (System Administrator use case) | | | | | ✓ | Planned |

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
| 401 | `INVALID_CREDENTIALS` | The username does not exist, **or** the password is wrong, **or** the account is invited and has no password yet. All three are deliberately identical, and take about the same time, so nobody can find out which usernames exist or which accounts are waiting for activation | Username or password is incorrect. |
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

## POST /auth/activate

Activates an officer or administrator account that an administrator created with
[`POST /admin/users`](#post-adminusers) (FR-10). The person types the activation code the
administrator gave them and chooses their own password, so nobody else ever knows it. The
answer is the same as a login's: the app is logged in at once.

| | |
|---|---|
| **Login needed** | No |
| **Rate limits** | 30 per IP per 15 minutes, every request counted, including invalid ones |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `username` | string | yes | Surrounding spaces are trimmed. 1–32 characters. Letter case does not matter |
| `code` | string | yes | 1–64 characters. Not trimmed. Typed as described below; whether it can be a code is decided by the server, and a value that cannot is simply a wrong code |
| `password` | string | yes | Not trimmed. 1–1024 characters, and must meet the [password policy](#post-authregister), including not containing the username |

Any other field is refused with `VALIDATION_FAILED`.

```json
{ "username": "chanda_mwale", "code": "7kq4 m2xd 9tne", "password": "copper hill solwezi" }
```

**The activation code.** 12 characters from the Crockford base32 alphabet
`0123456789ABCDEFGHJKMNPQRSTVWXYZ` (the digits and capital letters without I, L, O and U),
shown to the administrator once as three groups of four, for example `7KQ4-M2XD-9TNE`.
It carries 60 random bits.

- **How it may be typed:** in any letter case, with or without the hyphens, and with spaces
  anywhere. `O` is read as `0`, and `I` and `L` as `1`, because they look alike.
  `7kq4m2xd9tne`, `7KQ4 M2XD 9TNE` and `7KQ4-M2XD-9TNE` are the same code.
- **Anything else is a wrong code:** `U`, punctuation, a letter outside plain ASCII, or the
  wrong number of characters.
- **It works for 72 hours** from when it was issued, by the database's clock.
- **It works once.** After activation the account is no longer invited, and the same code
  gets 401.
- **5 wrong codes erase it.** The fifth wrong code removes the code and its expiry, and
  then even the right code is refused. An administrator issues a new one with
  [`POST /admin/users/{id}/activation-code`](#post-adminusersidactivation-code). An
  expired or erased code does not count as a wrong guess.

**The order of the checks.** The new password is checked against the policy first, before
the username or the code is looked at. A weak password is refused with `WEAK_PASSWORD`
without using up one of the 5 guesses, and the answer is the same whether or not the
username exists.

**200 OK**, with `Cache-Control: no-store`: exactly the shape of a
[login](#post-authlogin), with the account now `active`.

```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE",
  "tokenType": "Bearer",
  "expiresIn": 3600,
  "user": {
    "id": "3f2b6c1e-0000-4000-8000-000000000002",
    "username": "chanda_mwale",
    "fullName": "Chanda Mwale",
    "licenceNumber": null,
    "role": "officer",
    "status": "active",
    "createdAt": "2026-11-11T09:00:00.000Z",
    "publicKeyFingerprint": null
  }
}
```

**Errors.** Every response, errors included, carries `Cache-Control: no-store`.

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | A field is missing, empty, not a string or too long, or another field was sent | Some fields are missing or invalid. |
| 400 | `WEAK_PASSWORD` | The password breaks the policy. `details` lists each problem with `"field": "password"`, as at [registration](#post-authregister) | Choose a stronger password. |
| 400 | `INVALID_JSON` | The body is not valid JSON | Request body is not valid JSON |
| 401 | `ACTIVATION_INVALID` | **Every** other failure: the username does not exist, the account is not invited (already active, pending, and so on), it has no code (erased), the code has expired, the code is wrong, or it stopped working while this request was being handled. All are deliberately identical | This activation code is not valid. Ask an administrator for a new one. |
| 413 | `PAYLOAD_TOO_LARGE` | The body is over 100 kB | Request body is too large |
| 429 | `TOO_MANY_REQUESTS` | 30 requests from this IP in 15 minutes | Too many activation attempts from this network. Please try again later. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

**Recorded** in the audit log: a successful activation as `user.activate`, with the account
as the actor and empty details, in the same database transaction as the activation. Every
401 is recorded too, as `user.activation_failed` with a fixed `reason` (`unknown_username`,
`no_code`, `expired`, `wrong_code`, or `code_changed` when the code stopped working during
the request), and `codeErased: true` on the wrong code that erased it. An unknown username
is recorded with no actor, and the typed username is never stored. The code and the
password are never recorded anywhere.

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
| 401 | `TOKEN_INVALID` | Malformed, forged or tampered token, or the user no longer exists, or the role changed, or the token was issued before the account's last password change | Your session is not valid. Please log in again. |
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

## POST /auth/me/password

Changes the logged-in user's own password (FR-06), and ends every other session. The answer
is the same as a login's, with a fresh token: the phone that made the change swaps to it
and stays logged in. Every token issued before the change, on any phone, gets 401
`TOKEN_INVALID` from then on.

| | |
|---|---|
| **Login needed** | Yes, any role. The account must be active |
| **Rate limits** | 10 failed attempts per user per 15 minutes. Successful changes are not counted |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `currentPassword` | string | yes | Not trimmed. 1–1024 characters. Only checked against the stored password, so an older password that does not meet today's policy can still be replaced |
| `newPassword` | string | yes | Not trimmed. 1–1024 characters, and must meet the [password policy](#post-authregister), including not containing the username |

Any other field (for example `userId`) is refused with `VALIDATION_FAILED`. The password
changed is always the logged-in account's, never one named in the body.

```json
{ "currentPassword": "gold river kasempa", "newPassword": "copper hill solwezi" }
```

**The order of the checks**, each answered before the next is tried:

1. The new password against the policy (`WEAK_PASSWORD`). A weak choice is refused without
   the current password being tried, so it never adds to the failed attempts recorded.
2. The current password (`CURRENT_PASSWORD_INCORRECT`).
3. The new password is not the same as the current one (`PASSWORD_UNCHANGED`). The check
   uses the same comparison as login, so text typed with different but equivalent
   characters counts as the same password.

**200 OK**, with `Cache-Control: no-store`: exactly the shape of a
[login](#post-authlogin), with the fresh token.

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

- **Other sessions end.** The server stores the fresh token's issue time (`iat`, whole
  seconds) as the account's cut-off. A token issued before it is refused with the ordinary
  401 `TOKEN_INVALID`, which does not say why. The fresh token was issued in that very
  second, so it passes.
- **The old password stops working** at login at once; the new one works.
- **Recorded** in the audit log as `user.password_change` with `{ "sessionsEnded": true }`,
  in the same database transaction as the change. A wrong current password is recorded as
  `user.password_change_failed` with `{ "reason": "wrong_current_password" }`, kept even
  though the request fails. The weak and unchanged refusals are not recorded. No password
  or hash is ever recorded.

**Errors.** Every response, errors included, carries `Cache-Control: no-store`. The three
refusals are 400, never 401: the person is logged in, and a 401 would make the app throw
the session away over a typing mistake.

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | A field is missing, empty, not a string or over 1024 characters, another field was sent, or there is no body | Some fields are missing or invalid. |
| 400 | `WEAK_PASSWORD` | The new password breaks the policy. `details` lists each problem with `"field": "newPassword"` and the codes listed under [registration](#post-authregister) | Choose a stronger password. |
| 400 | `CURRENT_PASSWORD_INCORRECT` | The current password is wrong, or the password was changed by another request a moment ago. `details`: `[{ "field": "currentPassword", "message": "is not correct" }]` | Your current password is not correct. |
| 400 | `PASSWORD_UNCHANGED` | The new password is the current one. `details`: `[{ "field": "newPassword", "message": "must be different from your current password" }]` | Choose a password different from your current one. |
| 400 | `INVALID_JSON` | The body is not valid JSON | Request body is not valid JSON |
| 401 | `TOKEN_MISSING`, `TOKEN_INVALID`, `TOKEN_EXPIRED` | See [Authentication](#authentication) | |
| 403 | `ACCOUNT_PENDING`, `ACCOUNT_SUSPENDED`, `ACCOUNT_REJECTED` | The account is not active | See [Authentication](#authentication) |
| 413 | `PAYLOAD_TOO_LARGE` | The body is over 100 kB | Request body is too large |
| 429 | `TOO_MANY_REQUESTS` | 10 failed attempts by this user in 15 minutes | Too many failed password changes. Please wait 15 minutes and try again. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

---

## Admin account management

Eight endpoints let an administrator review account requests (FR-12), create officer and
administrator accounts and reissue their activation codes (FR-10), suspend or reactivate
accounts (FR-10), and remove a lost phone's device key. Changing a role and deleting an
account are planned for a later step.

**Account statuses.** Every account has one of five:

| Status | Meaning | Can log in |
|---|---|---|
| `pending` | A miner, transporter or buyer asked for an account ([`/auth/register`](#post-authregister)) and is waiting for approval | No (403 `ACCOUNT_PENDING`, after the right password) |
| `invited` | An administrator created this officer or administrator account ([`POST /admin/users`](#post-adminusers)); its owner has not activated it yet. It has no password at all | No: login answers `INVALID_CREDENTIALS`, as for an unknown username. Activate with [`/auth/activate`](#post-authactivate) |
| `active` | Approved or activated | Yes |
| `suspended` | Suspended by an administrator, with a reason | No (403 `ACCOUNT_SUSPENDED`) |
| `rejected` | The request was refused, with a reason. Final | No (403 `ACCOUNT_REJECTED`) |

An invited account is not active, so approve, reject, suspend, reactivate and reset key all
refuse it, and it never counts as one of the active administrators that must remain.

**Rules shared by all eight:**

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
  | Create | (new account) | `invited` | `{ "username", "fullName", "role" }` | `officer`, `admin` only |
  | Reissue activation code | `invited` | `invited` (a new code; the old one stops working) | none, or `{}` | `officer`, `admin` (the only invited accounts) |

  **Rejected is final.** No action leads out of `rejected`. The person must request a new
  account under a different username.
- **Two administrators acting at once:** the check and the change happen in one database
  step, so only one of them succeeds. The other gets 409 `INVALID_STATUS_TRANSITION`.
- **Every change is recorded** in the audit log, in the same database transaction, with the
  administrator as the actor, their IP address, and `{ from, to }` plus the reason where
  there is one. The actions are `user.approve`, `user.reject`, `user.suspend` and
  `user.reactivate`. A key reset is recorded as `user.key_reset` with `{ reason,
  keyFingerprint }`, naming the removed key by fingerprint. A created account is recorded
  as `user.create` with `{ source: "admin", role, activationExpiresAt }`, and a new code as
  `user.activation_reissue` with `{ activationExpiresAt }`. An activation code is never
  recorded.
- **`{id}`** is the user's id, a UUID. Upper- or lower-case letters are both accepted.

**Reasons.** Reject, suspend and reset key need a reason: 3 to 500 characters after surrounding spaces
are trimmed. Line breaks are allowed. **A reason is kept permanently** in the append-only
audit log, where it can never be edited or removed. Keep it short and factual, for example
`Licence number could not be verified`, and do not add personal details that are not needed.
The reason is shown to administrators only, never to the account's owner.

**The admin view of a user.** All eight endpoints return users in this form. Unlike
[`GET /auth/me`](#get-authme), it includes the status reason, the approval and the
activation expiry. It never contains the password hash, the on-chain reference, the
activation code or its hash, or the device key itself, only the key's fingerprint.

| Field | Meaning |
|---|---|
| `id` | The user's id |
| `username`, `fullName`, `licenceNumber`, `role`, `status` | As in `/auth/me` |
| `statusReason` | Why the account is suspended or rejected; `null` otherwise |
| `approvedBy` | The id of the administrator who approved the account; `null` if never approved through the API (for example a seeded account) |
| `approvedAt` | When it was approved; `null` with `approvedBy` |
| `createdAt`, `updatedAt` | When the account was requested, and when it last changed |
| `publicKeyFingerprint` | The SHA-256 fingerprint of the registered device key, as in [`/auth/me`](#get-authme); `null` when there is none. Lets an administrator see whether there is a key to reset, and compare it with the one the user's phone shows |
| `activationExpiresAt` | For an invited account with a code: when the code stops working. A time in the past means it has expired and a new one is needed. `null` for every other account, and for an invited account whose code was erased after 5 wrong attempts. A time, never a secret |

**Errors these endpoints can return**, on top of the [token errors](#authentication):

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | `{id}` is not a UUID; a reason is missing, too short or too long; a body or query has a field it should not | Some fields are missing or invalid. |
| 403 | `FORBIDDEN` | Logged in and active, but not an administrator | You do not have permission to do this. |
| 403 | `CANNOT_SUSPEND_SELF` | An administrator tried to suspend their own account | You cannot suspend your own account. |
| 404 | `USER_NOT_FOUND` | No user has this id | No user has this id. |
| 400 | `ROLE_NOT_CREATABLE` | Create with a role other than `officer` or `admin`. The request schema refuses it first (`VALIDATION_FAILED`, "must be officer or admin"); the service checks again for any other caller | Only officer and administrator accounts are created by an administrator. Miners, transporters and buyers register themselves. |
| 409 | `INVALID_STATUS_TRANSITION` | The account is not in the status this action starts from (for example approving an active account, resetting the key of an account that is not suspended, reissuing a code for an account that is not invited, or anything on a rejected one) | Only a pending account can be approved. This account is active. (The wording names the action and the actual status, with "an" before `active` and `invited`.) |
| 409 | `ROLE_NOT_APPROVABLE` | Approve or reject on an officer or administrator account. Those are created by an administrator, never requested | Officer and administrator accounts are created by an administrator, not approved or rejected. |
| 409 | `USERNAME_TAKEN` | Create with a username that exists already, in any letter case, whatever that account's status (invited, pending and rejected included) | That username is already taken. Please choose another. |
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
| `status` | `pending` | `pending`, `active`, `suspended`, `rejected` or `invited` |
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
      "publicKeyFingerprint": null,
      "activationExpiresAt": null
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

## POST /admin/users

Creates an officer or administrator account (FR-10). The account is `invited`: it has no
password and cannot log in until its owner [activates](#post-authactivate) it with the
activation code in this response and chooses their own password. Miners, transporters and
buyers request their own accounts with [`/auth/register`](#post-authregister) instead.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `username` | string | yes | As at [registration](#post-authregister): surrounding spaces are trimmed, 3–32 characters from `A–Z a–z 0–9 _ . -`, unique ignoring letter case |
| `fullName` | string | yes | Surrounding spaces are trimmed. 1–100 characters |
| `role` | string | yes | `officer` or `admin` ("must be officer or admin") |

Any other field is refused with `VALIDATION_FAILED`, including `password` (only the owner
ever chooses one) and `status` (a created account is always `invited`).

```json
{ "username": "chanda_mwale", "fullName": "Chanda Mwale", "role": "officer" }
```

**201 Created**

```json
{
  "user": {
    "id": "3f2b6c1e-0000-4000-8000-000000000002",
    "username": "chanda_mwale",
    "fullName": "Chanda Mwale",
    "licenceNumber": null,
    "role": "officer",
    "status": "invited",
    "statusReason": null,
    "approvedBy": null,
    "approvedAt": null,
    "createdAt": "2026-11-11T09:00:00.000Z",
    "updatedAt": "2026-11-11T09:00:00.000Z",
    "publicKeyFingerprint": null,
    "activationExpiresAt": "2026-11-14T09:00:00.000Z"
  },
  "activation": {
    "code": "7KQ4-M2XD-9TNE",
    "expiresAt": "2026-11-14T09:00:00.000Z"
  }
}
```

- **`activation.code` is shown here once and never again.** Only its SHA-256 hash is
  stored, so nobody, the administrator included, can read it back later. Hand it to the
  person directly (in person or by phone). A lost code is replaced with
  [`/activation-code`](#post-adminusersidactivation-code), not recovered.
- **It works for 72 hours** (`expiresAt`, worked out by the database's clock) and for at
  most 5 wrong attempts. The format, and how it may be typed, are under
  [`POST /auth/activate`](#post-authactivate).
- **`approvedBy` stays `null`:** nobody approved a request. The `user.create` audit entry
  records which administrator created the account.
- **Any active administrator may create another administrator.** There is no second
  approval; the creation is recorded.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `ROLE_NOT_CREATABLE` and `USERNAME_TAKEN`.
See [the shared table](#admin-account-management).

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
    "publicKeyFingerprint": null,
    "activationExpiresAt": null
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

---

## POST /admin/users/{id}/activation-code

Issues a new activation code for an **invited** account (FR-10): the old code was lost,
has expired, or was erased after 5 wrong attempts. The old code stops working at once,
the wrong-attempt count starts again at 0, and the new code works for 72 hours.

This is also how a mistaken invitation is withdrawn: reissue, and do not pass the new code
on. Nobody can then activate the account.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |
| **Request body** | None, or `{}`. Any field is refused |

```
POST /admin/users/3f2b6c1e-0000-4000-8000-000000000002/activation-code
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

**200 OK**: `{ "user": …, "activation": { "code": …, "expiresAt": … } }`, the same shape as
[creation](#post-adminusers), with the account still `invited`. As there, the new code is
shown once and never again.

**Recorded** in the audit log as `user.activation_reissue` with `{ activationExpiresAt }`,
never the code.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `USER_NOT_FOUND` and
`INVALID_STATUS_TRANSITION` ("Only an invited account can get a new activation code. This
account is active."). See [the shared table](#admin-account-management).

---

## GPS zone management (FR-11)

Five endpoints let an administrator manage the licensed extraction zones. Sync checks every
registration against the **active** zones (see [Flagged results](#flagged-results), code
`GPS_ZONE`), and records the matching zone on every step.

**Rules shared by all five:**

- **Admin only.** Every request needs a token, and the account must be an active `admin`.
  Anyone else gets 401 or 403 (see [Roles and access](#roles-and-access)). This applies to
  every path under `/admin/zones`, including paths that do not exist: a non-admin gets 403,
  not 404, so the paths cannot be discovered.
- **No caching.** Every response, errors included, carries `Cache-Control: no-store`.
- **Rate limits:** none yet, as for `/admin/users`.
- **A zone is never deleted.** Steps refer to the zone they were matched to, so a zone that
  is no longer licensed is deactivated instead.
- **The boundary and the licence number never change.** They are set when the zone is
  created, and no endpoint changes them. Every step's zone must keep meaning the shape that
  was checked when the step arrived. A new shape is a new zone: see
  [Replacing a zone](#replacing-a-zone).
- **Names are unique ignoring letter case, among active and inactive zones alike.**
  `Kasempa North` and `KASEMPA NORTH` cannot both exist, even if one of them is inactive.
- **Changes apply from the next sync.** Sync reads the active zones on every call, so a
  created, deactivated or reactivated zone is used from the next `POST /sync/steps`. Steps
  already stored keep their zone, and nothing is checked again.
- **Every change is recorded** in the audit log, in the same database transaction, with the
  administrator as the actor and their IP address. A refused request records nothing.

  | Action | Audit action | `details` |
  |---|---|---|
  | Create | `gps_zone.create` | `{ name, licenceNumber, cornerCount }` |
  | Rename | `gps_zone.rename` | `{ from, to }`: the old and new names |
  | Deactivate | `gps_zone.deactivate` | `{ from: "active", to: "inactive", reason, activeZonesLeft }` |
  | Reactivate | `gps_zone.reactivate` | `{ from: "inactive", to: "active" }` |

- **`{id}`** is the zone's id, a UUID. Upper- or lower-case letters are both accepted.

### The boundary

A boundary is a JSON array of corners, listed in order around the edge (either direction).
Each corner is **`[latitude, longitude]`, latitude first**. GeoJSON and many map tools write
`[longitude, latitude]`, so swap the two before sending such corners. In Google Maps,
right-clicking a spot shows "lat, lng" in the right order.

- **3 to 100 corners.**
- Each value is a **JSON number** (not a string), latitude between −90 and 90, longitude
  between −180 and 180, with **at most 6 decimal places**. More places are refused, not
  rounded.
- **Do not close the ring.** The edge from the last corner back to the first is implied, so
  do not repeat the first corner at the end, as GeoJSON does.

The shape is then checked. These rules run only once every corner is valid, so a bad corner
is reported on its own first:

| Rule | Field | Message |
|---|---|---|
| No corner repeats the one before it | that corner | repeats the corner before it; list each corner once |
| The last corner is not the first one again | the last corner | repeats the first corner; list each corner once, without repeating the first corner at the end |
| At least 3 different corners | `boundary` | must have at least 3 different corners |
| Every corner is inside a rough box around Zambia (latitude −18.5 to −8.0, longitude 21.5 to 34.0). Only the first corner outside it is reported. This mainly catches corners sent as `[longitude, latitude]` | the first corner outside | is outside Zambia; each corner must be [latitude, longitude], latitude first (in Zambia, latitude is about -8 to -18 and longitude about 22 to 34) |
| The shape encloses at least 100 square metres | `boundary` | must enclose at least 100 square metres; check that the corners are not all on one line |
| The shape fits within 50 km from north to south and from east to west | `boundary` | must fit within 50 km from north to south and from east to west |

**Field paths.** A problem with one corner names it by its position, counting from 0:
`boundary.3` is the fourth corner, and `boundary.1.0` is the latitude of the second corner.
A problem with the shape as a whole is named `boundary`. For example, a closed triangle
(4 corners, the last repeating the first):

```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Some fields are missing or invalid.",
    "details": [
      {
        "field": "boundary.3",
        "message": "repeats the first corner; list each corner once, without repeating the first corner at the end"
      }
    ]
  }
}
```

**Not checked:** edges that cross each other (a "bow-tie"), holes, zones made of several
polygons, and zones that overlap. Two overlapping active zones are allowed; a point in both
is matched to one of them by a fixed rule.

### The zone view

All five endpoints return zones in this form.

| Field | Meaning |
|---|---|
| `id` | The zone's id |
| `name` | The zone's name, as shown in reports and alerts |
| `licenceNumber` | The licence the zone belongs to; `null` if none was given |
| `status` | `active` (registrations are checked against it) or `inactive` |
| `boundary` | The corners, as `[latitude, longitude]` pairs, exactly as created |
| `createdBy` | The id of the administrator who created the zone |
| `createdAt`, `updatedAt` | When the zone was created, and when it last changed (a rename or a status change) |

### Replacing a zone

A boundary cannot be edited, so a corrected or changed licence area is a new zone. Because
names stay taken by inactive zones, the old zone is renamed first:

1. [Rename](#post-adminzonesidrename) the old zone, for example to
   `Kasempa North (until Nov 2026)`.
2. [Create](#post-adminzones) the new zone with the original name.
3. [Deactivate](#post-adminzonesiddeactivate) the old zone.

A zone is active at every moment, so no registration is flagged during the change. For a
moment both zones are active, which is harmless. The same flow corrects a wrong licence
number.

### No active zones left

Deactivating the last active zone is allowed: a revoked licence must be able to go. The
response is still **200**, and carries a warning:

```json
{
  "code": "NO_ACTIVE_ZONES",
  "message": "No GPS zone is active now, so every new registration will be flagged as outside a licensed zone until a zone is created or reactivated."
}
```

The app should show it to the administrator. While no zone is active, every registration is
stored as flagged (`GPS_ZONE`). A warning is never missed, even when two administrators
deactivate the last two zones at the same moment: the second waits for the first, and
exactly one of them is warned. It can rarely be a false alarm, if another administrator
reactivates a zone at that same moment; listing the active zones shows the real state.

**Errors these endpoints can return**, on top of the [token errors](#authentication):

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | `{id}` is not a UUID; a name, licence number, boundary or reason breaks a rule above; a body or query has a field it should not (for example `boundary` sent to rename). Each problem is named by its field path, such as `boundary.3` | Some fields are missing or invalid. |
| 403 | `FORBIDDEN` | Logged in and active, but not an administrator | You do not have permission to do this. |
| 404 | `ZONE_NOT_FOUND` | No zone has this id | No GPS zone has this id. |
| 409 | `ZONE_NAME_TAKEN` | Another zone, active or inactive, already has this name in any letter case | A GPS zone with this name already exists. Names are compared ignoring letter case and include inactive zones. Choose another name, or rename the other zone first. |
| 409 | `INVALID_STATUS_TRANSITION` | Deactivating a zone that is already inactive, or reactivating one that is already active | Only an active zone can be deactivated. This zone is inactive. (The wording names the action and the actual status.) |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

---

## GET /admin/zones

Lists zones with one status, by name, ignoring letter case. With no query it lists the
first page of active zones: the ones registrations are checked against.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |
| **Request body** | None |

**Query parameters**

| Parameter | Default | Rules |
|---|---|---|
| `status` | `active` | `active` or `inactive` |
| `limit` | `20` | Whole number, 1 to 100 |
| `offset` | `0` | Whole number, 0 to 10 000: how many matching zones to skip |

As for [`GET /admin/users`](#get-adminusers), `limit` and `offset` must be plain digits, and
any other parameter is refused with `VALIDATION_FAILED`.

**200 OK**: `{ "zones": [ … ], "total": 1, "limit": 20, "offset": 0 }`, each zone in
[the zone view](#the-zone-view). `total` counts every zone with that status, not only this
page.

**Errors:** `VALIDATION_FAILED` and `FORBIDDEN`.

---

## POST /admin/zones

Creates a zone. It is `active` at once, so the next sync checks registrations against it.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `name` | string | yes | Surrounding spaces are trimmed. 3–100 characters. Unique ignoring letter case, among active and inactive zones |
| `licenceNumber` | string | no | Surrounding spaces are trimmed. 1–50 characters. Cannot be changed later |
| `boundary` | array | yes | See [The boundary](#the-boundary). Cannot be changed later |

Any other field, such as `status` or `createdBy`, is refused. The creator is always the
administrator who sent the request.

```
POST /admin/zones
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
Content-Type: application/json
```

```json
{
  "name": "Kasempa North",
  "licenceNumber": "DEMO-LML-0001",
  "boundary": [
    [-13.45, 25.82],
    [-13.47, 25.86],
    [-13.49, 25.81]
  ]
}
```

**201 Created**

```json
{
  "zone": {
    "id": "7a1c2d3e-0000-4000-8000-0000000000aa",
    "name": "Kasempa North",
    "licenceNumber": "DEMO-LML-0001",
    "status": "active",
    "boundary": [
      [-13.45, 25.82],
      [-13.47, 25.86],
      [-13.49, 25.81]
    ],
    "createdBy": "3f2b6c1e-0000-4000-8000-0000000000ad",
    "createdAt": "2026-11-10T09:00:00.000Z",
    "updatedAt": "2026-11-10T09:00:00.000Z"
  }
}
```

**Errors:** `VALIDATION_FAILED` (with field paths, such as `boundary.3`), `FORBIDDEN` and
`ZONE_NAME_TAKEN`.

---

## POST /admin/zones/{id}/rename

Renames an active or inactive zone. Only the name changes. Alerts already raised keep the
name they were raised with.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `name` | string | yes | As for [create](#post-adminzones) |

`boundary` and `licenceNumber` are refused here, because they cannot change.

```json
{ "name": "Kasempa North (until Nov 2026)" }
```

**200 OK**: `{ "zone": { … } }` with the new name.

- **The same name** (exactly the same text) changes nothing and records nothing; the
  answer is still 200 with the zone.
- **A change of letter case only**, such as `kasempa north` to `Kasempa North`, is allowed,
  and recorded.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `ZONE_NOT_FOUND` and `ZONE_NAME_TAKEN`.

---

## POST /admin/zones/{id}/deactivate

Makes an active zone `inactive`. Registrations synced after this are no longer matched to it.
Steps already stored keep the zone they were matched to.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |

**Request body**: `reason`, with the same rules as for
[rejecting an account](#post-adminusersidreject): 3–500 characters after trimming. The
reason is kept only in the audit log, permanently; the zone itself has no reason field.

```
POST /admin/zones/7a1c2d3e-0000-4000-8000-0000000000aa/deactivate
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
Content-Type: application/json
```

```json
{ "reason": "Licence revoked" }
```

**200 OK**: `{ "zone": { … }, "warning": null }`, or, when this was the last active zone,
the [`NO_ACTIVE_ZONES` warning](#no-active-zones-left):

```json
{
  "zone": {
    "id": "7a1c2d3e-0000-4000-8000-0000000000aa",
    "name": "Kasempa North",
    "licenceNumber": "DEMO-LML-0001",
    "status": "inactive",
    "boundary": [
      [-13.45, 25.82],
      [-13.47, 25.86],
      [-13.49, 25.81]
    ],
    "createdBy": "3f2b6c1e-0000-4000-8000-0000000000ad",
    "createdAt": "2026-11-10T09:00:00.000Z",
    "updatedAt": "2026-11-10T11:30:00.000Z"
  },
  "warning": {
    "code": "NO_ACTIVE_ZONES",
    "message": "No GPS zone is active now, so every new registration will be flagged as outside a licensed zone until a zone is created or reactivated."
  }
}
```

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `ZONE_NOT_FOUND` and
`INVALID_STATUS_TRANSITION` (the zone is already inactive).

---

## POST /admin/zones/{id}/reactivate

Makes an inactive zone `active` again, with its original boundary. Registrations synced
after this are checked against it.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None yet |
| **Request body** | None, or `{}`. Any field is refused |

**200 OK**: `{ "zone": { … } }` with `"status": "active"`.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `ZONE_NOT_FOUND` and
`INVALID_STATUS_TRANSITION` (the zone is already active).

---

## Anchoring administration

Three endpoints let an administrator see how anchoring on Sepolia is going (FR-03), and
recover when it stops: a status page, a button that runs one tick of the worker now, and a
retry for a step that failed for a reason that can be tried again. Anchoring failures are
an administrator's concern, not officer alerts (decisions log, Anomaly rules (8)).

**Rules shared by all three:**

- **Admin only.** Every request needs a token, and the account must be an active `admin`.
  Anyone else gets 401 or 403 (see [Roles and access](#roles-and-access)). This applies to
  every path under `/admin/anchoring`, including paths that do not exist: a non-admin gets
  403, not 404, so the paths cannot be discovered.
- **No caching.** Every response, errors included, carries `Cache-Control: no-store`.
- **Rate limit: 20 actions per 15 minutes per administrator**, run and retry together, one
  count for both. It counts every request that passes the role check, including invalid
  ones. A non-admin is refused before it and not counted. Over the limit: **429
  `TOO_MANY_REQUESTS`**, "Too many anchoring actions. Please wait a few minutes and try
  again.", with `Retry-After` (see [Rate limits](#rate-limits)). **The status is not
  limited**: it only reads.
- **No chain call inside a request.** The status is built from the database and the
  worker's memory, and a retry changes the database only. Both answer even while the RPC
  provider is down. Only a run talks to the chain, through the worker.
- **No secret in any answer.** No RPC URL, key, `ANCHOR_*` setting or text from the RPC
  provider. The two addresses shown are public on Sepolia.
- **Every action is recorded** in the audit log, with the administrator as the actor and
  their IP address. A refusal, and the status, record nothing.

  | Action | Audit action | Entity | `details` |
  |---|---|---|---|
  | Run | `anchoring.run` | none | `{ outcome, code, stepId }` from the tick's summary |
  | Retry | `transaction.anchor_retry` | the step (`transaction`) | `{ reason, previousError, previousAttempts, previousTxHash }` |

- **`{id}`** is the step's id (the `transactions` row), a UUID. Upper- or lower-case letters
  are both accepted.
- **With `ANCHOR_ENABLED` not `true`** there is no worker. The status still answers from the
  database, with `worker.state` `disabled`, and a run is refused with `ANCHORING_DISABLED`.

### Problems

The status lists what needs attention as `{ code, message }`, in this order. An empty list
means nothing does.

| Code | When | Message |
|---|---|---|
| `WORKER_DISABLED` | `worker.state` is `disabled` | Anchoring is switched off (ANCHOR_ENABLED is not true), so no step reaches the chain. |
| `WORKER_NOT_STARTED` | `worker.state` is `not_started` | The anchoring worker has not started because its startup check did not pass. Fix the configuration, then restart. |
| `WORKER_STOPPED` | `worker.state` is `stopped` | The anchoring worker has stopped: the recorder wallet lost its role, or the server is shutting down. |
| `WORKER_BACKOFF` | `worker.state` is `backoff` | The anchoring worker cannot reach the chain and is trying again with growing delays. |
| `WORKER_PAUSED` | `worker.state` is `paused` | The anchoring worker is paused: the wallet cannot pay, the fee is above the cap, or another transaction is waiting. |
| `STUCK_SUBMITTED` | A step in `inFlight` has `stuck: true` | A sent step has not moved for more than 5 minutes. Nothing else can be anchored until it does. |
| `FAILED_STEPS` | `counts.failed` is more than 0 | Some steps failed to anchor. Later steps of the same consignment wait behind them. |
| `NO_RECENT_TICK` | The worker should be ticking (`running`, `paused` or `backoff`) but its last sign of life (the last tick, else the start, else the last preflight) is more than 3 × `ANCHOR_INTERVAL_SECONDS` old; while backing off, the 300 s backoff cap is added to that | The anchoring worker has not finished a tick for longer than expected. |

The problems are only shown on this page. Nothing is pushed to an administrator's phone yet
(push notifications need the device token table, D10).

### Which failed steps can be retried

A retry sends a step from `failed` back to `pending` by changing the database only, so it
is allowed only for failures where nothing of ours can be on-chain. The allow-list matches
the code, and the detail where there is one:

| `anchor_error` code | Retry? | Why |
|---|---|---|
| `INVALID_STAGE:None` | Yes | The registration may be on-chain by now; the next dry run checks again |
| `UNKNOWN` | Yes | Often a passing fault; the next dry run checks again |
| `MAX_ATTEMPTS` | Yes | Every try was mined and reverted, and a reverted transaction changes nothing on-chain |
| `INVALID_STAGE:Registered`, `INVALID_STAGE:InTransit`, `INVALID_STAGE:Purchased` | No | The chain's stage forbids the step; it would fail again |
| `INVALID_INPUT:…`, `STEP_TYPE_UNKNOWN`, `BYTES32_INVALID`, `WEIGHT_INVALID` | No | Stored data the contract refuses: a backend bug |
| `ID_ALREADY_ANCHORED` | No | The consignment id is on-chain with another hash; needs investigating |
| `RECEIPT_MISMATCH:…` | Never | Something was written on-chain; a retry could anchor the step twice |

Anything else, including text not in the `CODE[:detail]: reason` format, is refused.

**A stuck `submitted` step has no endpoint.** Its transaction may still be mined, and a
handoff can be anchored twice, so it is never released by hand. The status shows it
(`stuck`, `lastRefusal`). Then:

- **`FEE_TOO_HIGH` or `INSUFFICIENT_FUNDS`:** raise `ANCHOR_MAX_FEE_GWEI` or fund the
  recorder wallet. The worker resends with the same nonce by itself, or at once with
  [a run](#post-adminanchoringrun).
- **A refused dry run** (any other code): a bug. Stop and investigate.

**Errors these endpoints can return**, on top of the [token errors](#authentication):

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | The status was sent any query parameter; a run was sent a body field; `{id}` is not a UUID ("must be a valid step id", checked before the body); the reason is missing, under 3 or over 500 characters after trimming, or comes with another field | Some fields are missing or invalid. |
| 403 | `FORBIDDEN` | Logged in and active, but not an administrator | You do not have permission to do this. |
| 404 | `STEP_NOT_FOUND` | Retry: no step has this id | No step has this id. |
| 409 | `INVALID_STATUS_TRANSITION` | Retry: the step is `pending`, `submitted` or `confirmed` | Only a failed step can be retried. This step is pending. (The wording names the actual status.) |
| 409 | `ANCHOR_NOT_RETRYABLE` | Retry: the step failed for a reason not on the allow-list above | This step failed for a reason a retry cannot fix (RECEIPT_MISMATCH). It needs investigating. (The wording names the code.) |
| 409 | `ANCHORING_DISABLED` | Run: `ANCHOR_ENABLED` is not `true` | Anchoring is switched off on this server (ANCHOR_ENABLED is not true), so there is nothing to run. |
| 409 | `ANCHORING_NOT_STARTED` | Run: the worker's startup check has not passed (it failed, or is still being retried) | The anchoring worker has not started, because its startup check has not passed. The status shows which check; it may still be retrying. |
| 409 | `ANCHORING_STOPPED` | Run: the recorder wallet lost `RECORDER_ROLE`, or the server is shutting down | The anchoring worker has stopped: the recorder wallet lost its role, or the server is shutting down. It runs again only after a restart. |
| 409 | `ANCHORING_BUSY` | Run: a tick is already running in this server, or another process (such as `anchor:once`) holds the anchoring lock | Anchoring is already running a tick. Try again in a moment. |
| 429 | `TOO_MANY_REQUESTS` | More than 20 runs and retries in 15 minutes | Too many anchoring actions. Please wait a few minutes and try again. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault, including a run whose tick finished but whose audit entry could not be written | Something went wrong |

---

## GET /admin/anchoring

The anchoring status. Read from the database in one consistent snapshot (`REPEATABLE READ`,
no locks, so the worker is never held up) and from the worker's memory.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | None |
| **Query** | None. Any parameter is refused |

**200 OK**, for example while a step is stuck behind a fee above the cap (all values fake):

```json
{
  "worker": {
    "state": "running",
    "startedAt": "2026-11-12T08:00:00.000Z",
    "preflight": { "at": "2026-11-12T08:00:00.000Z", "passed": true, "retrying": false, "checks": [] },
    "lastTick": { "at": "2026-11-12T09:59:45.000Z", "outcome": "waiting", "code": null, "stepId": null },
    "recorderAddress": "0x25E19030C6cdb1e2608819BceF797a23eb0738fA",
    "contractAddress": "0x6419cB5268706E2aA4713AB3bCFc336248Ed158a"
  },
  "counts": { "pending": 2, "submitted": 1, "confirmed": 41, "failed": 0 },
  "inFlight": [
    {
      "stepId": "9d4e5f60-0000-4000-8000-000000000001",
      "consignmentId": "5c0d7e21-0000-4000-8000-000000000001",
      "type": "handoff",
      "chainTxHash": "0x1111111111111111111111111111111111111111111111111111111111111111",
      "nonce": "41",
      "submittedAt": "2026-11-12T09:50:00.000Z",
      "ageSeconds": 600,
      "stuck": true,
      "lastRefusal": {
        "code": "FEE_TOO_HIGH",
        "detail": null,
        "error": "FEE_TOO_HIGH: the network fee is above the configured maximum"
      }
    }
  ],
  "failed": [],
  "pending": {
    "oldestReceivedAt": "2026-11-12T09:40:00.000Z",
    "oldestAgeSeconds": 1200,
    "onHeldConsignments": 0,
    "behindFailedStep": 0,
    "sendableNow": "9d4e5f60-0000-4000-8000-000000000002"
  },
  "held": [],
  "lastConfirmed": { "stepId": "9d4e5f60-0000-4000-8000-000000000003", "anchoredAt": "2026-11-12T09:49:36.000Z" },
  "lastSubmitted": { "stepId": "9d4e5f60-0000-4000-8000-000000000001", "submittedAt": "2026-11-12T09:50:00.000Z" },
  "problems": [
    { "code": "STUCK_SUBMITTED", "message": "A sent step has not moved for more than 5 minutes. Nothing else can be anchored until it does." }
  ]
}
```

**`worker`**, from the worker's memory in this server process:

| Field | Meaning |
|---|---|
| `state` | `running`; `backoff` (the last tick, or the startup check, could not reach the chain, or the tick failed unexpectedly; retrying with growing delays); `paused` (the last tick could not send: funds, fee, or another transaction from the wallet waiting); `stopped` (the wallet lost `RECORDER_ROLE`, or the server is shutting down); `not_started` (the startup check failed, or has not run); `disabled` (`ANCHOR_ENABLED` is not `true`) |
| `startedAt` | When the startup check passed and the timer started; `null` before |
| `preflight` | `null` until the first startup check, then `{ at, passed, retrying, checks }`. `retrying` is `true` when the check could not be made (the RPC was down) and will be tried again. `checks` lists only the checks that did not pass, as `{ name, status }`: `name` is `chainId`, `code` or `role`, `status` is `failed` (a person must fix the configuration), `error` (could not be checked) or `skipped` (an earlier check did not pass). Never the problem text, which names RPC hosts |
| `lastTick` | `null` until the first tick, then `{ at, outcome, code, stepId }` of the last one, from the timer or a run. `outcome` is `idle`, `sent`, `waiting`, `refused`, `paused`, `backoff`, `busy`, `stopped`, or `error` for a tick that failed unexpectedly (its `code` is then always `INTERNAL_ERROR`, never the error's text) |
| `recorderAddress`, `contractAddress` | The recorder wallet (fund this one) and the MineChain contract; `null` when disabled |

Ticks run by the `anchor:once` script happen in another process and are not in `worker`;
they show in the rows (`lastSubmitted`, `lastConfirmed`).

**`counts`**: steps by `anchor_status`, counting **approved steps only** (`review_status`
`passed` or `cleared`). A flagged step is waiting for an officer, not for the chain.

**`inFlight`**: every approved `submitted` step, in nonce order (normally at most one).

| Field | Meaning |
|---|---|
| `stepId`, `consignmentId`, `type` | The step |
| `chainTxHash` | The transaction last sent for it |
| `nonce` | The recorder wallet's nonce, as text (a big integer) |
| `submittedAt`, `ageSeconds` | When it was last sent (a same-nonce resend refreshes it), and how long ago |
| `stuck` | `true` when `ageSeconds` is more than 300 (5 minutes) |
| `lastRefusal` | `null`, or why the last resend was refused: `{ code, detail, error }`, where `error` is the stored text. Cleared when a resend goes through |

**`failed`**: the newest 50 failed steps (by when the row last changed), each with
`stepId`, `consignmentId`, `type`, `code` and `detail` (split from `error`, the stored
reason), `attempts`, `chainTxHash` (the reverted or mismatched transaction, or `null`),
`updatedAt`, and `retryable` (on the [allow-list](#which-failed-steps-can-be-retried)).
`counts.failed` has the full number.

**`pending`**, over the approved `pending` steps, by the queue's own rules:

| Field | Meaning |
|---|---|
| `oldestReceivedAt`, `oldestAgeSeconds` | The oldest one, and how long it has waited; `null` when none |
| `onHeldConsignments` | How many are on a consignment held by an open alert (an officer releases it) |
| `behindFailedStep` | How many wait behind an earlier failed step of their consignment (retrying that step frees them) |
| `sendableNow` | The step the worker would send next, or `null`. A hint: it can be out of date a moment later |

**`held`**: up to 50 held consignments with approved steps waiting, oldest first, each as
`{ consignmentId, qrCode, pendingSteps, openAlerts }`. `openAlerts` counts every open alert
on the consignment's steps.

**`lastConfirmed`**, **`lastSubmitted`**: the most recently anchored step (`anchoredAt`, the
block's time) and the most recently sent one (`submittedAt`), from the rows; `null` when
none.

**`problems`**: see [Problems](#problems).

**Errors:** `VALIDATION_FAILED` (a query parameter) and `FORBIDDEN`.

---

## POST /admin/anchoring/run

Runs **one** tick of the anchoring worker now, on the same worker as the timer: it
reconciles every `submitted` step, then sends at most one new step. Useful straight after a
fix, such as funding the wallet. It never runs "until idle", and does not move the timer's
next tick. It does not wake a service that Render has spun down; the request itself does
that.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | 20 runs and retries per 15 minutes per administrator, together |
| **Request body** | None, or `{}`. Any field is refused |

**200 OK**: the tick's summary.

```json
{
  "summary": {
    "outcome": "sent",
    "reconciled": { "confirmed": 1, "waiting": 0, "resent": 0, "returnedToPending": 0, "failed": 0 },
    "stepId": "9d4e5f60-0000-4000-8000-000000000002",
    "code": null
  }
}
```

| Field | Meaning |
|---|---|
| `outcome` | `idle` (nothing to send), `sent`, `waiting` (a step is still in flight), `refused` (the dry run refused a step; it was retried or failed), `paused` (funds, fee, or another transaction waiting), `backoff` (the RPC could not be reached), or `stopped` (this tick found the wallet has lost its role) |
| `reconciled` | What happened to the steps that were in flight: confirmed, still waiting, resent with the same nonce, returned to pending, failed |
| `stepId`, `code` | The step the outcome is about, and its code, or `null` |

The run is recorded as `anchoring.run`. If the tick finished but its audit entry could not
be written, the answer is 500: whatever the tick did stays done (it is what the next timer
tick would have done), and one server log line names the administrator and the outcome.

**Errors:** `VALIDATION_FAILED` (a body field), `FORBIDDEN`, `ANCHORING_DISABLED`,
`ANCHORING_NOT_STARTED`, `ANCHORING_STOPPED`, `ANCHORING_BUSY` and `TOO_MANY_REQUESTS`.

---

## POST /admin/anchoring/steps/{id}/retry

Sends a `failed` step back to `pending`, so the worker tries it again from the start: no
attempts, no hash, a fresh nonce. Only for codes on the
[allow-list](#which-failed-steps-can-be-retried). Steps after it on the same consignment,
which were waiting behind it, are freed too.

| | |
|---|---|
| **Login needed** | Yes, admin only |
| **Rate limits** | 20 runs and retries per 15 minutes per administrator, together |

**Request body**: `reason`, with the same rules as for
[rejecting an account](#post-adminusersidreject): 3–500 characters after trimming. It is
kept only in the audit log, permanently, with the step's previous error, attempts and
transaction hash, which the step itself loses.

```
POST /admin/anchoring/steps/9d4e5f60-0000-4000-8000-000000000004/retry
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
Content-Type: application/json
```

```json
{ "reason": "The RPC provider was down during the first try" }
```

**200 OK**: the step as it is now.

```json
{
  "step": {
    "stepId": "9d4e5f60-0000-4000-8000-000000000004",
    "consignmentId": "5c0d7e21-0000-4000-8000-000000000002",
    "type": "registration",
    "anchorStatus": "pending",
    "code": "RETRY_REQUESTED",
    "detail": null,
    "error": "RETRY_REQUESTED: an administrator asked for this step to be tried again",
    "attempts": 0,
    "chainTxHash": null,
    "updatedAt": "2026-11-12T10:05:00.000Z"
  }
}
```

The step is locked while it is checked and changed, so two administrators retrying it at
the same moment cannot both succeed: the second gets 409 `INVALID_STATUS_TRANSITION`. The
change and its audit entry are saved together, or not at all.

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `STEP_NOT_FOUND`, `INVALID_STATUS_TRANSITION`,
`ANCHOR_NOT_RETRYABLE` and `TOO_MANY_REQUESTS`.

---

## Reports (FR-09, FR-13)

Two endpoints download records as spreadsheet files (CSV): the custody steps in a period
(FR-09), and the full audit trail of one consignment or one actor (FR-13), for an officer to
hand to the regulator.

**Rules shared by both:**

- **Who may use them.** Every request needs a token, and the account must be an active
  `officer`, `buyer` or `admin`. Anyone else gets 401 or 403 (see
  [Roles and access](#roles-and-access)). This applies to every path under `/reports`,
  including paths that do not exist: a miner or transporter gets 403, not 404, so the paths
  cannot be discovered. The audit trail is for officers only: a buyer or admin gets 403 there.
- **A buyer sees only what they bought.** In the transactions report, a buyer gets only the
  consignments they have an accepted purchase of (`passed` or `cleared`), and of those only
  the accepted steps. Another buyer's consignment, and any flagged or rejected step, are never
  in a buyer's file. Officers and admins see every step.
- **No caching.** Every response, errors included, carries `Cache-Control: no-store`.
- **Rate limit: 20 downloads per 15 minutes per account**, both reports together. It counts
  every request that passes the role check above, including invalid ones and audit-trail
  requests from a buyer or admin (refused straight after). A miner or transporter is refused
  before it and not counted. Over the limit: **429 `TOO_MANY_REQUESTS`**, "Too many report
  downloads. Please wait a few minutes and try again.", with `Retry-After` (see
  [Rate limits](#rate-limits)).
- **At most 10,000 rows.** A report that would be longer is refused with 422
  `REPORT_TOO_LARGE`, never cut short: a shortened file handed to the regulator would look
  complete. Choose a shorter period or add a filter.
- **Every download is recorded** in the audit log, with the account as the actor and its IP
  address. The rows and the audit entry are read and written in one database transaction, so
  a file is never sent without its record. A refused request records nothing.

  | Report | Audit action | Entity | `details` |
  |---|---|---|---|
  | Transactions | `report.transactions_export` | none | `{ filters, scope, rowCount }`; `scope` is `own_purchases` for a buyer, `all` otherwise |
  | Audit trail | `report.audit_trail_export` | the consignment, or the user | `{ filters, rowCount }` |

  `filters` are the query parameters as validated, with ids in lower case.

### The file

- **Format:** CSV as in RFC 4180. Fields are separated by commas, every record ends with CRLF
  (`\r\n`), the last one included, and **every field is in double quotes**, with a `"` inside
  written as `""`. The first record is a header row of the column names below. A report with
  no rows is the header row alone.
- **Encoding:** UTF-8, starting with a byte order mark (the bytes `EF BB BF`). Without it,
  Excel on Windows guesses another encoding and garbles characters outside ASCII.
- **Headers:** `Content-Type: text/csv; charset=utf-8`, and `Content-Disposition: attachment;
  filename="…"`, so the file is saved rather than shown. The filename contains only lower-case
  letters, digits, `.` and `-`:

  | Report | Filename |
  |---|---|
  | Transactions | `minechain-transactions-{from}-to-{to}.csv` |
  | Audit trail, one consignment | `minechain-audit-trail-consignment-{consignmentId}.csv` |
  | Audit trail, one actor | `minechain-audit-trail-user-{actorId}-{from}-to-{to}.csv` |

- **Times are UTC**, in ISO 8601 with milliseconds, for example `2026-11-10T06:00:00.000Z`.
  Zambia is UTC+2, so that is 08:00 in Lusaka. An empty cell means "none".
- **Weights** are given twice: `weight_mg`, the whole milligrams as signed, and `weight_kg`,
  the same value in kilograms with always 6 decimal places (`1500000` mg is `1.500000`). The
  kilograms are worked out from the digits, never with floating-point arithmetic, so they are
  exact.
- **Coordinates** are the signed values with 6 decimal places, latitude first.
- **Hashes** are `0x` followed by 64 lower-case hex characters.

**Cells that start like a formula.** A spreadsheet treats a cell starting with `=`, `+`, `-`
or `@` as a formula, and a tab or carriage return at the start can hide one. Several text
fields come from people (a licence number typed at registration, a QR code, a zone name, an
officer's notes), so a text cell starting with one of those six characters gets a **single
quote (`'`) in front**. Spreadsheets show such a cell as plain text instead of running it.
**A leading `'` was added by the server; the original value is the rest of the cell.** For
example, the licence number `=HYPERLINK("http://x","y")` is written as
`"'=HYPERLINK(""http://x"",""y"")"`. Number and time cells (weights, coordinates, block
numbers, times) are never changed this way: they can only ever hold digits, a point, a minus
sign or a timestamp, so `-15.419012` stays a number. Only the first character is checked.

**Errors these endpoints can return**, on top of the [token errors](#authentication). They
are JSON, as everywhere else, never CSV:

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | A query parameter is missing, invalid or not allowed (see each endpoint). Each problem is named by its field; a problem with the query as a whole is named `query` | Some fields are missing or invalid. |
| 403 | `FORBIDDEN` | Logged in and active, but this role may not use this report | You do not have permission to do this. |
| 404 | `CONSIGNMENT_NOT_FOUND` | Audit trail: no consignment has this id | No consignment has this id. |
| 404 | `USER_NOT_FOUND` | Audit trail: no user has this id | No user has this id. |
| 422 | `REPORT_TOO_LARGE` | More than 10,000 rows | This report has more than 10,000 rows. Choose a shorter date range or add a filter. |
| 429 | `TOO_MANY_REQUESTS` | More than 20 downloads in 15 minutes | Too many report downloads. Please wait a few minutes and try again. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault | Something went wrong |

---

## GET /reports/transactions

The custody steps recorded in a period, one row per step, ordered by when the phone recorded
them (FR-09).

| | |
|---|---|
| **Login needed** | Yes, officer, buyer (own purchases only) or admin |
| **Rate limits** | 20 per 15 minutes per account, shared with the audit trail |
| **Request body** | None |

**Query parameters**

| Parameter | Required | Rules |
|---|---|---|
| `from` | yes | A UTC day, `YYYY-MM-DD`, that exists on the calendar |
| `to` | yes | The same, on or after `from`. The period is at most **366 days, counting both** `from` and `to` |
| `mineral` | no | `gold`, `copper`, `cobalt`, `manganese`, `emerald` or `amethyst` |
| `actorId` | no | A user id (UUID): steps by that person |
| `zoneId` | no | A zone id (UUID): steps matched to that zone |
| `type` | no | `registration`, `handoff` or `purchase` |
| `reviewStatus` | no | `passed`, `flagged`, `cleared` or `rejected` |
| `anchorStatus` | no | `pending`, `submitted`, `confirmed` or `failed` |

- **Both days are included, in UTC:** `from=2026-11-01&to=2026-11-30` covers every step
  recorded from `2026-11-01T00:00:00.000Z` up to, but not including,
  `2026-12-01T00:00:00.000Z`.
- **The period is about when the phone recorded the step** (`captured_at_utc`), not when it
  reached the server.
- Every filter given must match. A parameter may appear once; any other parameter is refused.

**Order:** by `captured_at_utc`; steps recorded at the same moment are ordered by
`received_at_utc`, which follows custody order; then by `step_id`, so the order never varies.

**Columns**

| Column | Meaning |
|---|---|
| `step_id` | The step's id |
| `consignment_id`, `qr_code`, `mineral` | The consignment |
| `consignment_stage` | The consignment's stage **now** (`registered`, `in_transit` or `purchased`), not at the time of the step |
| `step_type` | `registration`, `handoff` or `purchase` |
| `actor_username`, `actor_role`, `actor_licence_number` | Who recorded the step. Full names are never included |
| `weight_mg`, `weight_kg` | The weight, see [The file](#the-file) |
| `latitude`, `longitude` | Where the step was recorded |
| `zone_name`, `zone_licence_number` | The licensed zone the point was matched to; empty when it was outside every active zone |
| `captured_at_utc` | When the phone recorded the step (the phone's clock, covered by the signature) |
| `received_at_utc` | When the server received it (the server's clock) |
| `review_status` | `passed`, `flagged`, `cleared` or `rejected` |
| `anchor_status` | `pending`, `submitted`, `confirmed` or `failed` |
| `chain_tx_hash`, `block_number`, `anchored_at_utc` | The Sepolia transaction, its block, and the block's time. **Only for `confirmed` steps**: a submitted transaction can still be dropped and replaced, so its hash is not final. Empty otherwise |
| `data_hash` | The hash recorded on-chain for this step. It is public on Sepolia, and lets anyone check the step against the chain |

```
GET /reports/transactions?from=2026-11-10&to=2026-11-10&mineral=gold
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

**200 OK**, `minechain-transactions-2026-11-10-to-2026-11-10.csv` (fake values; two records
shown, each one line in the file):

```
"step_id","consignment_id","qr_code","mineral","consignment_stage","step_type","actor_username","actor_role","actor_licence_number","weight_mg","weight_kg","latitude","longitude","zone_name","zone_licence_number","captured_at_utc","received_at_utc","review_status","anchor_status","chain_tx_hash","block_number","anchored_at_utc","data_hash"
"7a3e9b10-0000-4000-8000-000000000001","5c0d7e21-0000-4000-8000-000000000001","MC-2026-000001","gold","purchased","registration","mutale_banda","miner","DEMO-ASM-0001","1500000","1.500000","-13.450000","25.820000","Kasempa North","DEMO-LML-0001","2026-11-10T06:00:00.000Z","2026-11-10T06:05:12.345Z","passed","confirmed","0xabababababababababababababababababababababababababababababababab","12047700","2026-11-10T06:07:24.000Z","0xcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
```

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN`, `REPORT_TOO_LARGE` and `TOO_MANY_REQUESTS`. See
[the shared table](#reports-fr-09-fr-13).

---

## GET /reports/audit-trail

Everything that happened to one consignment, or everything one actor did in a period, one
row per event in time order (FR-13). For officers only.

| | |
|---|---|
| **Login needed** | Yes, officer only |
| **Rate limits** | 20 per 15 minutes per account, shared with the transactions report |
| **Request body** | None |

**Query parameters:** exactly one of `consignmentId` and `actorId`.

| Parameter | Rules |
|---|---|
| `consignmentId` | A consignment id (UUID). Its whole trail, from registration on. `from` and `to` are refused with it |
| `actorId` | A user id (UUID). Requires `from` and `to` |
| `from`, `to` | With `actorId` only: UTC days, both included, at most 366 days, as for the [transactions report](#get-reportstransactions) |

Neither id, or both, is refused with `"field": "query"`.

**Events**

| `event` | When (`event_time_utc`) | In which trail |
|---|---|---|
| `step_recorded` | The server received a step (its `received_at`) | both |
| `alert_raised` | An anomaly check raised an alert on a step | both |
| `step_anchored` | The step's Sepolia transaction was mined (the block's time) | both |
| `alert_reviewed`, `alert_dismissed` | An officer closed an alert. Officer review is still to be built; these rows appear once alerts can be closed | both |
| `account_event` | A change to the actor's account: `user.create`, `user.register`, `user.approve`, `user.reject`, `user.suspend`, `user.reactivate`, `user.key_register`, `user.key_reset`, `user.activation_reissue`, `user.activate` or `user.password_change`. Logins, and failed logins, activations and password changes, are not included | actor only |

- **An actor's trail** contains the steps that actor recorded, the alerts and anchoring of
  those steps, and their account events. Steps by other people on the same consignments are
  not in it. The period applies to each event's own time, so a step recorded before `from`
  but anchored inside the period shows only its `step_anchored` row.
- **Order:** by `event_time_utc`. Events at the same moment follow the order of the table
  above (`step_recorded`, `alert_raised`, `step_anchored`, then the closing of an alert, then
  `account_event`), then by id, so the order never varies.

**Columns**

| Column | Meaning |
|---|---|
| `event_time_utc`, `event` | When, and what (above) |
| `consignment_id`, `qr_code`, `mineral` | The consignment; empty on `account_event` rows |
| `step_id`, `step_type` | The step the event is about; empty on `account_event` rows |
| `actor_username`, `actor_role`, `actor_licence_number` | On step and alert rows, who recorded the step. **On `account_event` rows, who made the change**: an administrator for an approval or suspension, the user themselves for a registration or key, empty for the seed |
| `weight_mg`, `weight_kg`, `latitude`, `longitude`, `zone_name`, `captured_at_utc` | The step, as in the transactions report |
| `review_status` | The step's review status **now** |
| `alert_id`, `alert_type`, `alert_severity`, `alert_status` | On alert rows, the alert |
| `alert_details` | On alert rows, the alert's details as JSON (see [database-schema.md](database-schema.md), `details` per alert type) |
| `reviewer_username`, `review_notes` | On a closed alert, the officer and their notes |
| `chain_tx_hash`, `block_number` | On `step_anchored` rows only |
| `data_hash` | On every step and alert row |
| `account_action`, `account_details` | On `account_event` rows: the action, and its details as JSON. IP addresses are never included |

```
GET /reports/audit-trail?consignmentId=5c0d7e21-0000-4000-8000-000000000001
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
```

**200 OK**, `minechain-audit-trail-consignment-5c0d7e21-0000-4000-8000-000000000001.csv`
(fake values; the header and two of the rows, each one line in the file):

```
"event_time_utc","event","consignment_id","qr_code","mineral","step_id","step_type","actor_username","actor_role","actor_licence_number","weight_mg","weight_kg","latitude","longitude","zone_name","captured_at_utc","review_status","alert_id","alert_type","alert_severity","alert_status","alert_details","reviewer_username","review_notes","chain_tx_hash","block_number","data_hash","account_action","account_details"
"2026-11-10T07:02:10.101Z","step_recorded","5c0d7e21-0000-4000-8000-000000000001","MC-2026-000001","gold","7a3e9b10-0000-4000-8000-000000000002","handoff","chanda_mwale","transporter","","1200000","1.200000","-13.460000","25.840000","","2026-11-10T07:00:00.000Z","flagged","","","","","","","","","","0xefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef","",""
"2026-11-10T07:02:10.104Z","alert_raised","5c0d7e21-0000-4000-8000-000000000001","MC-2026-000001","gold","7a3e9b10-0000-4000-8000-000000000002","handoff","chanda_mwale","transporter","","1200000","1.200000","-13.460000","25.840000","","2026-11-10T07:00:00.000Z","flagged","3b1f0c9e-0000-4000-8000-000000000001","quantity_discrepancy","medium","open","{""weightMg"": ""1200000"", ""thresholdPercent"": 10}","","","","","0xefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef","",""
```

**Errors:** `VALIDATION_FAILED`, `FORBIDDEN` (any role but officer),
`CONSIGNMENT_NOT_FOUND`, `USER_NOT_FOUND`, `REPORT_TOO_LARGE` and `TOO_MANY_REQUESTS`. A
trail for an id that does not exist is refused rather than sent as an empty file, which would
look like "nothing happened". See [the shared table](#reports-fr-09-fr-13).

---

## POST /sync/steps

Uploads signed custody steps from the phone's offline queue (FR-03, FR-07): registrations by
miners, handoffs by transporters and purchases by buyers. Each step is the exact text the
phone signed, with its signature, as defined in the [signing spec](signing-spec.md). The
server verifies each one, stores it as evidence, and later anchors it on Sepolia.

| | |
|---|---|
| **Login needed** | Yes: miner, transporter or buyer. Officers and administrators get 403 `FORBIDDEN` |
| **Rate limits** | 60 requests per 15 minutes **per user** (not per IP: many phones at one site share an IP). Over the limit: 429 `TOO_MANY_REQUESTS` with `Retry-After` |

**Request body**

| Field | Type | Required | Rules |
|---|---|---|---|
| `steps` | array | yes | 1 to 50 items, processed in this order |
| `steps[].payload` | string | yes | The exact signed text (signing spec, section 3), 1–512 characters. Not trimmed or changed |
| `steps[].signature` | string | yes | The DER signature in standard base64, 1–100 characters |

Any other field, at either level (for example `actorId` or `receivedAt`), is refused with
`VALIDATION_FAILED`. The actor is always the logged-in user, and the server sets every other
value itself, including the time it received the step.

A queue longer than 50 steps is sent as several requests, oldest steps first. Fifty steps is
about 25 kB, so a full batch uploads in a few seconds on 3G.

```
POST /sync/steps
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE
Content-Type: application/json
```

```json
{
  "steps": [
    {
      "payload": "minechain-step/1/handoff\nstep_id=6f1d2c3a-0000-4000-8000-000000000002\nactor_id=3f2b6c1e-0000-4000-8000-000000000002\nqr_code=MC-2026-000123\nweight_mg=1495000\nlatitude=-15.390012\nlongitude=28.322540\ncaptured_at=2026-11-10T14:30:05.250Z\n",
      "signature": "MEUCIQFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE="
    }
  ]
}
```

In JSON, each line break of the payload is written `\n`; decoding gives back the exact
signed text.

**200 OK**, with `Cache-Control: no-store`, whenever the batch was processed, whatever each
step's outcome. One result per step, in the order sent:

```json
{
  "results": [
    { "index": 0, "stepId": "6f1d2c3a-0000-4000-8000-000000000002", "outcome": "created",
      "transactionId": "7a3e9b10-0000-4000-8000-000000000001", "reviewStatus": "passed" },
    { "index": 1, "stepId": "6f1d2c3a-0000-4000-8000-000000000002", "outcome": "duplicate",
      "transactionId": "7a3e9b10-0000-4000-8000-000000000001", "reviewStatus": "passed" },
    { "index": 2, "stepId": "6f1d2c3a-0000-4000-8000-000000000003", "outcome": "flagged",
      "code": "INVALID_SIGNATURE",
      "message": "The record was saved, but its signature did not match your device key. An officer will review it.",
      "transactionId": "7a3e9b10-0000-4000-8000-000000000002", "reviewStatus": "flagged",
      "alerts": ["invalid_signature"] },
    { "index": 3, "stepId": null, "outcome": "rejected", "code": "PAYLOAD_MALFORMED",
      "message": "This record is not in the signed format the server expects." },
    { "index": 4, "stepId": "6f1d2c3a-0000-4000-8000-000000000004", "outcome": "deferred",
      "code": "CONSIGNMENT_NOT_FOUND",
      "message": "This consignment has not reached the server yet. Keep the record and sync again later." }
  ]
}
```

| Result field | Present | Meaning |
|---|---|---|
| `index` | always | The step's position in the request, from 0 |
| `stepId` | always | The `step_id` from the payload, or `null` if the payload could not be read |
| `outcome` | always | One of the five outcomes below |
| `code`, `message` | flagged, rejected, deferred | A stable code for the app's logic, and a plain-language message to show the user |
| `transactionId` | created, duplicate, flagged | The stored step's id |
| `reviewStatus` | created, duplicate, flagged | `passed` or `flagged` (later also `cleared` or `rejected`, after an officer's review) |
| `alerts` | flagged | The alert types raised, for example `["invalid_signature"]` |

### The five outcomes

| Outcome | Stored? | Meaning | What the app does |
|---|---|---|---|
| `created` | yes | Stored, and every check passed | Mark the step as synced and remove it from the queue |
| `duplicate` | already | This exact step was stored before (a retry, for example after a lost response). Nothing new was written | The same as `created` |
| `flagged` | yes | Stored as evidence, but a check failed. An alert is open for an officer, and the consignment is **held** until it is reviewed | Remove it from the queue, and show the user that the step is under review |
| `rejected` | no | Can never be accepted as it is. Sending it again unchanged will give the same answer | **Keep the record** (it is signed evidence) and show the code. Never delete it silently |
| `deferred` | not yet | Valid, but something it depends on has not reached the server yet | Keep it in the queue **unchanged**, and send it again with the next sync, with growing pauses. Show the user any step deferred for more than 72 hours |

### Codes

The app must branch on `code`, never on `message`. Codes are stable; messages are plain
language for the user and may be reworded.

| Code | Outcome | Meaning | What the app does |
|---|---|---|---|
| `INVALID_SIGNATURE` | flagged | The signature did not verify against the account's registered device key. The record may have been changed after signing, or signed on another phone | Show "under review". Check that `publicKeyFingerprint` on `/auth/me` matches this phone's key |
| `DUPLICATE_CONSIGNMENT` | flagged | A registration for a QR code that is already registered. It is stored on the existing consignment, whose miner and stage do not change | Show "under review". Check the custody record that was scanned |
| `HANDOFF_ORDER` | flagged | A handoff or purchase for a consignment that is already `purchased`, the final stage | Show "under review" |
| `QUANTITY_DISCREPANCY` | flagged | A handoff or purchase whose weight differs by more than 10% from the latest earlier accepted step, or from the accepted registration | Show "under review" |
| `GPS_ZONE` | flagged | A registration whose location is outside every active GPS zone, allowing 25 m for GPS error. With no active zone at all, every registration gets this | Show "under review" |
| `PAYLOAD_MALFORMED` | rejected | Not a valid signed payload (wrong bytes, lines, order or values) | An app bug: report it, keep the record |
| `PAYLOAD_UNSUPPORTED_VERSION` | rejected | The payload's format version is not one this server reads | Ask the user to update the app |
| `SIGNATURE_MALFORMED` | rejected | Not strict base64, or not 8–72 bytes | An app bug: report it, keep the record |
| `ACTOR_MISMATCH` | rejected | The payload's `actor_id` is not the logged-in user | Make sure the account that signed the step is the one logged in |
| `STEP_NOT_ALLOWED_FOR_ROLE` | rejected | Registration is for miners, handoff for transporters, purchase for buyers | An app bug: the app should not offer this step to this role |
| `STEP_ID_CONFLICT` | rejected | A **different** record with the same `step_id` was already stored for this user | An app bug: every step needs a fresh `step_id`. Keep both records |
| `NO_DEVICE_KEY` | deferred | The account has no registered device key yet | Register the key ([`PUT /auth/me/public-key`](#put-authmepublic-key)), then send the step again |
| `CONSIGNMENT_NOT_FOUND` | deferred | No consignment has this QR code yet: most likely the miner's registration has not been synced | Send it again later. It will be accepted once the registration arrives |
| `STAGE_NOT_READY` | deferred | A purchase while the consignment is still at `registered`. Either the transporter's handoff has not been synced yet, or it is stored but flagged and waiting for an officer's review (a flagged step does not move the stage) | Send it again later. It will be accepted once a handoff is accepted |

### Flagged results

A flagged step was stored, so the app removes it from the queue and must not send it again.
Every check runs on every step, so one step can fail several. `code` names the **most
severe** finding; between findings of the same severity, the first in check order wins.
The order is: signature, duplicate consignment, handoff order, quantity, GPS zone. `alerts`
lists the type of every alert stored for the step, in that same order.

| Code | Alert type | Severity | `message` |
|---|---|---|---|
| `INVALID_SIGNATURE` | `invalid_signature` | high | The record was saved, but its signature did not match your device key. An officer will review it. |
| `DUPLICATE_CONSIGNMENT` | `duplicate_consignment` | high | This custody record was already registered. Your record was saved, and an officer will review it. |
| `HANDOFF_ORDER` | `handoff_order` | high for a purchase, medium for a handoff | This consignment has already been sold. Your record was saved, and an officer will review it. |
| `QUANTITY_DISCREPANCY` | `quantity_discrepancy` | medium | The record was saved, but the weight differs by more than 10% from an earlier step. An officer will review it. |
| `GPS_ZONE` | `gps_zone` | medium | The record was saved, but its location is outside every registered extraction zone. An officer will review it. |

For example, a registration that is both a duplicate and outside every zone gets `code`
`DUPLICATE_CONSIGNMENT` (high beats medium) and `alerts`
`["duplicate_consignment", "gps_zone"]`.

The `STAGE_NOT_READY` message is: "This consignment is not ready for this step yet. An
earlier step has not reached the server, or is waiting for an officer's review. Keep the
record and sync again later."

The shape of each alert's `details` is in [database-schema.md](database-schema.md#alerts).

### How the server handles a batch

- **Steps are processed one at a time, in the order sent, each in its own database
  transaction.** One bad step never stops the others, and nothing is ever half-saved.
- **A retry is always recognised first,** before any rule about the consignment, so a step
  stored yesterday comes back as `duplicate` even if the consignment has moved on since.
- **The consignment's stage moves only for passed steps:** a handoff moves it to
  `in_transit` (a second handoff is a relay and leaves it there), and a purchase moves it to
  `purchased`, which is final. A flagged step is stored, but leaves the stage where it was.
- **If the server fails part-way through** (500 `INTERNAL_ERROR`), the steps already stored
  stay stored. Sending the whole batch again is safe: they come back as `duplicate`.
- Each stored step is recorded in the audit log as `transaction.create`. Rejected and
  deferred steps are not recorded.

**Errors** (for the whole request; individual steps never cause these)

| Status | Code | When | Message |
|---|---|---|---|
| 400 | `VALIDATION_FAILED` | No `steps`, 0 or more than 50 steps, a field that is missing, empty, too long or not allowed | Some fields are missing or invalid. |
| 400 | `INVALID_JSON` | The body is not valid JSON | Request body is not valid JSON |
| 401 | `TOKEN_MISSING`, `TOKEN_INVALID`, `TOKEN_EXPIRED` | See [Authentication](#authentication) | |
| 403 | `ACCOUNT_PENDING`, `ACCOUNT_SUSPENDED`, `ACCOUNT_REJECTED` | The account is not active | See [Authentication](#authentication) |
| 403 | `FORBIDDEN` | An officer or administrator account, which never signs custody steps | You do not have permission to do this. |
| 413 | `PAYLOAD_TOO_LARGE` | The body is over 100 kB | Request body is too large |
| 429 | `TOO_MANY_REQUESTS` | 60 requests from this user in 15 minutes | Too many sync requests. Please wait a few minutes and try again. |
| 500 | `INTERNAL_ERROR` | Unexpected server fault. Steps already stored stay stored; resending is safe | Something went wrong |

Every response, errors included, carries `Cache-Control: no-store`.
