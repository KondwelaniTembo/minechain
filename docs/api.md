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
    "createdAt": "2026-11-05T09:00:00.000Z"
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
    "createdAt": "2026-11-05T09:00:00.000Z"
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
    "createdAt": "2026-11-05T09:00:00.000Z"
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
