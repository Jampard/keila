# OIDC SSO

## What it does

Keila can authenticate users against one or more OpenID Connect providers,
using the `oidcc` / `oidcc_plug` libraries (authorization code flow with
PKCE, state and nonce).

The feature is **off by default**. With no `KEILA_OIDC_PROVIDERS` set (or no
provider passing validation), no provider configuration worker starts, and
`Keila.Auth.Oidc.enabled?/0` is `false`.

Multiple named providers can run simultaneously — e.g. a staff provider on
an internal IdP and a customer-facing one — each with its own client
credentials, scopes, label and policy.

## The staff door is not on the sign-in page

`staff` is a reserved provider name. The sign-in page renders a button for
every configured provider **except** `staff`; the staff door is `/staff`,
which nothing links to and which redirects to `/auth/oidc/staff`.

Staff and customers authenticate at different IdPs, so a staff button on a
customer-facing page is an entrance nobody reading that page can pass — it
invites a support ticket at best and, when the staff IdP is unreachable from
where the customer is, a dead link. Staff are told the URL instead.

Two consequences worth knowing before configuring an instance:

- With `staff` as the ONLY provider, the sign-in page offers nothing at all.
  That is the intended fail-closed answer, not a misconfiguration — but it
  means a customer-facing instance always needs a non-`staff` provider.
- `/staff` redirects unconditionally. When no `staff` provider is configured
  the authorize leg it lands on answers 404, so the door refuses rather than
  starting a flow that cannot complete.

## Configuration

All configuration is via environment variables, read once at boot in
`config/runtime.exs`. `KEILA_OIDC_PROVIDERS` is a list of provider names,
split on commas, spaces, tabs or newlines. Each name `NAME` (case
insensitive; upper-cased to build variable names, lower-cased to build the
internal provider key) has its own set of `KEILA_OIDC_<NAME>_*` variables.

| Variable | Required | Default | Notes |
|---|---|---|---|
| `KEILA_OIDC_PROVIDERS` | to enable OIDC at all | unset (OIDC disabled) | space/comma/tab/newline-separated list of provider names |
| `KEILA_OIDC_<NAME>_ISSUER` | yes | — | provider skipped if missing |
| `KEILA_OIDC_<NAME>_CLIENT_ID` | yes | — | provider skipped if missing |
| `KEILA_OIDC_<NAME>_CLIENT_SECRET` | yes | — | provider skipped if missing; `…_CLIENT_SECRET_FILE` reads it from a file |
| `KEILA_OIDC_<NAME>_SCOPES` | no | `openid email profile` | space/comma/tab/newline-separated; if set but empty, falls back to the default rather than requesting no scopes |
| `KEILA_OIDC_<NAME>_LABEL` | no | the provider name, capitalized (e.g. `staff` → `Staff`) | |
| `KEILA_OIDC_<NAME>_POLICY` | no | `entitlement` | `entitlement` or `pushed`, case-insensitive; **any other value (including the removed `tenant_spn`) refuses boot** |
| `KEILA_OIDC_<NAME>_ENTITLEMENT_CLAIM` | for the `entitlement` policy | unset | see Policies below — unset means nobody can sign in via this provider |
| `KEILA_OIDC_<NAME>_ENTITLEMENT_VALUE` | for the `entitlement` policy | unset | see Policies below — unset means nobody can sign in via this provider |
| `KEILA_OIDC_<NAME>_ADMIN_VALUE` | no | unset (no OIDC user gains admin) | `entitlement` policy only — see Administrators below |
| `KEILA_OIDC_<NAME>_TENANT_PREFIX`, `…_TENANT_CLAIM` | must be unset | — | leftovers of the removed `tenant_spn` policy; **either one refuses boot** |
| `KEILA_OIDC_<NAME>_CACERTFILE` | for an IdP behind a private CA | unset (system trust store) | PEM path — see Private certificate authorities below |
| `KEILA_TENANCY_SECRET` | to accept the tenancy push | unset (`/tenancy*` answers 404) | bearer secret; `KEILA_TENANCY_SECRET_FILE` reads it from a file — see Tenancy push below |
| `KEILA_OIDC_ONLY` | no | off | any value other than unset, empty, `0`, `false` or `FALSE` turns it on (so `False`, `no`, `1`, `true` all turn it on) — see OIDC-only mode below |

The variables are parsed in the OIDC SSO block of `config/runtime.exs`; the
defaults are `@default_scopes`, `@default_policy` and `default_label/1` in `Keila.Auth.Oidc` (`lib/keila/auth/oidc.ex`).

### Incomplete configuration

If any of `ISSUER`, `CLIENT_ID` or `CLIENT_SECRET` is missing (or empty) for
a provider name listed in `KEILA_OIDC_PROVIDERS`, that provider is dropped
entirely: a boot-time warning names the specific missing variables, and
**every other configured provider still starts normally**. An unrecognized
`_POLICY` value is different: it refuses boot, so a stale configuration fails
the deploy instead of running without its provider. There is no partial state for a single
provider — it is either fully valid or entirely absent from
`Keila.Auth.Oidc.providers/0`.

### Worked example: two providers

```
KEILA_OIDC_PROVIDERS="staff merchant"

KEILA_OIDC_STAFF_ISSUER=https://idp.example.com/oauth2/openid/keila-staff
KEILA_OIDC_STAFF_CLIENT_ID=keila-staff
KEILA_OIDC_STAFF_CLIENT_SECRET=s3cret-staff
KEILA_OIDC_STAFF_SCOPES="openid email profile groups"
KEILA_OIDC_STAFF_LABEL="Sign in with Staff SSO"
KEILA_OIDC_STAFF_POLICY=entitlement
KEILA_OIDC_STAFF_ENTITLEMENT_CLAIM=keila_role
KEILA_OIDC_STAFF_ENTITLEMENT_VALUE=keila_users

KEILA_OIDC_MERCHANT_ISSUER=https://idp.example.com/oauth2/openid/keila-merchant
KEILA_OIDC_MERCHANT_CLIENT_ID=keila-merchant
KEILA_OIDC_MERCHANT_CLIENT_SECRET=s3cret-merchant
KEILA_OIDC_MERCHANT_SCOPES="openid email profile groups"
KEILA_OIDC_MERCHANT_LABEL="Sign in with your organization"
KEILA_OIDC_MERCHANT_POLICY=pushed
```

This produces two independent providers, `staff` (entitlement-gated) and
`merchant` (admitting only the people the platform pushed), each reachable at its own callback path (see
Setting up kanidm below). Only `merchant` gets a button — `staff` is reached
at `/staff`, per the section above.

### Private certificate authorities

An IdP whose certificate is issued by a private CA — an internal PKI, or a
development instance with generated certificates — is not in the system trust
store, so every call to it fails with an `Unknown CA` TLS alert. Point the
provider at the CA's PEM:

```
KEILA_OIDC_MERCHANT_CACERTFILE=/etc/keila/idp-ca.pem
```

The file must be the **CA** certificate, not the server's own certificate, and
must be readable by the user Keila runs as. It applies to all four calls the
provider makes — discovery, JWKS, the token exchange and userinfo — each of
which opens its own connection, so a partial configuration fails midway through
sign-in rather than at startup.

Two things to know before setting it:

- It **replaces** the system trust store for this provider rather than adding to
  it. A provider pointed at a private CA can no longer verify a publicly-issued
  certificate, which is what you want for an internal IdP and wrong for a public
  one. Set it per provider, never globally.
- Verification is never disabled. There is no option to skip certificate
  checking; if the IdP's certificate cannot be verified against the file, sign-in
  fails. `allow_unsafe_http` does not help here — it relaxes the *scheme* check
  for `http://` endpoints and has no effect on an untrusted certificate chain.

If the CA rotates, keep the path stable and replace the file in place. Erlang's
TLS layer caches PEM files, so restart Keila if a replaced CA is not picked up.

## Policies

### `entitlement` (default)

A static check: the claim named by `KEILA_OIDC_<NAME>_ENTITLEMENT_CLAIM`
must contain the value in `KEILA_OIDC_<NAME>_ENTITLEMENT_VALUE`, matched
**exactly and case-sensitively**, among that claim's value(s) (the claim may
be a single string or a list of strings; non-string list elements are
dropped).

**Both halves are required.** If either `_ENTITLEMENT_CLAIM` or
`_ENTITLEMENT_VALUE` is not set, **nobody can sign in through that
provider** — an unconfigured gate is closed, not open
(`Keila.Auth.Oidc.Login.entitlement_gate/2` returns
`{:error, :provisioning_disabled}` in that case). There is deliberately no
presence-only mode: a claim name without a value would admit everyone at
the IdP holding any value for that claim.

The check runs on **every** sign-in, not only the first: a user who is
already linked but no longer carries the required claim value is refused on
their next login. Removing someone from the group at the IdP revokes their
Keila access on their next sign-in attempt.

### `pushed`

The provider admits only people the platform has pushed (see Tenancy push
below). Sign-in finds the User by `{issuer, sub}` and refuses anyone without
that identity row (`:not_entitled`); it never provisions, never reads the
email claim and never grants anything. Which projects a person reaches is
decided by the push alone. At most one provider may carry this policy: with
none or several, the tenancy push answers 503.

## Tenancy push

With `KEILA_TENANCY_SECRET` set, Keila implements the platform's tenancy
contract v1 on the app port:

| Route | Answer |
|---|---|
| `PUT /tenancy/{slug}` | `{version, state, name, domains[], members[{sub, mail, role}]}` → 200 `{applied: true}` or `{ignored: true}` |
| `GET /tenancy/{slug}` | `{version, state, members[{sub, role}]}`, or 404 when unknown or purged |
| `GET /tenancy` | `[{slug, version}]` of every shop not purged |

Every route needs `Authorization: Bearer <secret>` (401 `{"error":"unauthorised"}`
otherwise). A malformed body, including one that is not JSON, is 422
`{"error": "<field>: <why>"}` and applies nothing. A version at or below the
last one applied for the slug is ignored. The route must never be on a public
vhost.

Each slug is one shop: an Account, a Project group under it and a Project
named after `name`, recorded in the `tenancies` table. Members join the
Project group only — never the Account group, never a role — so a send from
the project debits that shop's Account alone. A member is matched by
`{pushed issuer, sub}`; a new sub becomes a password-less User and the push
owns its email (a mail held by another User is 422).

- `live`: the pushed members hold the project; anyone the push dropped loses it.
- `suspended`: the data stays, every pushed member loses access.
- `purged`: the Account and its group are deleted, which cascades to the
  Project and its data. Users are never deleted. The row stays as a
  tombstone at that version, so a later push only re-creates the shop fresh
  with a higher version.

## OIDC-only mode

`KEILA_OIDC_ONLY=true` disables password-based sign-in, registration and
password resets. The `block_password_auth` plug in `KeilaWeb.AuthController`
fires on `:post_login`, `:register`, `:post_register`, `:reset`,
`:post_reset`, `:reset_change_password` and `:post_reset_change_password`,
and renders `oidc_only.html` instead. It does **not** fire on `:login`,
which still renders the provider buttons with the password form hidden;
`:post_login` is the actual authentication boundary. Nor does it cover
`:logout`, `:activate`, `:activate_required` or `:post_activate_resend` — a
still-signed-in session can still sign out, and an already-issued
activation link still works.

Two things to know:

- OIDC-only only takes effect when at least one provider passes validation
  (`Keila.Auth.Oidc.oidc_only?/0` is `Keyword.get(config, :oidc_only, false)
  and enabled?()`) — setting the flag with no valid provider configured
  does not lock anyone out, because password auth stays the only option.
- **There is no per-account exemption by design.** If you need password
  sign-in back (e.g. to reach the admin UI, or because every configured
  provider is down), the break-glass procedure is: unset `KEILA_OIDC_ONLY`
  and restart the instance. There is no admin toggle for this, and no way to
  carve out a single account.

## Administrators

By default, users provisioned through OIDC are **not** Keila
administrators. Admin permission (`administer_keila`) is held by the root
user created by `priv/repo/seeds.exs` via `KEILA_USER` and
`KEILA_PASSWORD` — a password-authenticated account. Under
`KEILA_OIDC_ONLY` that account cannot sign in, so without the mapping below
the admin pages are unreachable until you go through the break-glass
procedure above.

`KEILA_OIDC_<NAME>_ADMIN_VALUE` (`entitlement` policy only) maps IdP-held
admin to Keila admin: a user whose entitlement claim also carries this
value is granted the root role on sign-in. The grant **reconciles on every
sign-in, both ways** — leaving the admin group at the IdP revokes
`administer_keila` at that user's next login. A provider configuring
`ADMIN_VALUE` therefore owns root-role membership for every user who signs
in through it, including a grant made by hand; with the variable unset, no
grant is ever made *or removed*. It has no effect on a `pushed`
provider.

`KEILA_PASSWORD` is authoritative on **every boot**, not only at first
seed: when it is set and the root user's password differs, the password is
updated during startup (`Keila.ReleaseTasks.sync_root_password/0`, keyed on
`KEILA_USER`, default `root@localhost`). Rotating the secret and restarting
is sufficient; the seed script itself still runs only on an empty database.

## Provisioning and account linking

On first successful sign-in, a new Keila user is created with no password
set, and is pre-activated (no activation email is sent — the IdP has
already verified the address; `email_verified: false` in the claims refuses
the sign-in instead, see below).

An IdP-managed account (one with an identity from a configured provider)
cannot set a local password, neither through a password reset nor on the
account page: a local password would keep working after the IdP revokes
access.

Identity is keyed on `{issuer, sub}`, never on email
(`oidc_identities` has a unique index on `[:issuer, :subject]`). This means:

- An email change at the IdP does not break the link — the existing
  `oidc_identities` row is found by issuer+subject regardless of the
  current email claim.
- Two different providers presenting the same `sub` value are two different
  people, because the issuer is part of the key.

**If the claimed email already belongs to an existing Keila account
(case-insensitively), sign-in is refused rather than silently linked.**
Auto-linking by email would let anyone who can rename an email address at
the IdP take over an existing Keila account. This is a deliberate refusal,
not a bug.

Refusals an operator might see in the logs
(`Keila.Auth.Oidc.Login.do_handle_claims/2`), in the order they're checked:

| Reason | When |
|---|---|
| `:invalid_claims` | `iss` or `sub` missing/empty in the token claims |
| `:provisioning_disabled` | the provider's gate (`_ENTITLEMENT_CLAIM` / `_ENTITLEMENT_VALUE`) is unset |
| `:not_entitled` | the entitlement check failed, or a `pushed` provider was never pushed this `sub` |
| `:missing_email` | no `email` claim on first sign-in (no existing identity to fall back to) |
| `:email_not_verified` | `email_verified` claim is explicitly `false` |
| `:email_exists` | the claimed email already belongs to a different Keila account |
| `:provisioning_failed` | user/identity row could not be created and no concurrent winner was found either |
| `:unknown_provider` | the `:provider` in the request does not match a currently valid, enabled provider |

A user who is already linked (existing `oidc_identities` row) skips the
email checks entirely on subsequent logins — only the policy gate is
re-evaluated.

## Setting up kanidm

This section describes what to configure; it does not give exact `kanidm`
CLI invocations that were not verified against a running instance.

1. **Create an OAuth2 client** ("RS") in kanidm for Keila, one per Keila
   provider you intend to run (e.g. one for `staff`, one for `merchant`).
2. **Redirect URL**: `https://<keila-host>/auth/oidc/<provider>/callback`,
   where `<provider>` is the lower-cased provider name from
   `KEILA_OIDC_PROVIDERS` (matching `KeilaWeb.OidcClientStore`, which
   resolves the provider from the `:provider` path parameter).
3. **Scope map**: must include `openid` (Keila's default scope list is
   `openid email profile`; add `groups` if you intend to use either
   entitlement policy's claim-based gating, since `entitlement_claim` is
   not populated by the default scopes alone).
4. **Claim map for the `entitlement` policy**: map a claim (e.g.
   `keila_role`) to the group(s) that should be allowed to sign in, and set
   `KEILA_OIDC_<NAME>_ENTITLEMENT_CLAIM=keila_role` and
   `KEILA_OIDC_<NAME>_ENTITLEMENT_VALUE=<the group's mapped value>`.

**Trap:** with the `groups` scope, kanidm emits both a UUID and an SPN for
every group a user belongs to, all in one flat list claim. That claim is
heterogeneous by design — `Keila.Auth.Oidc.Claims` only pattern-matches
strings that fit the shape it expects (a single required string for
`entitlement`); anything else
in the list, including the UUID entries, is silently skipped rather than
causing an error.

kanidm signs ID tokens with ES256 by default (RS256 requires enabling
legacy crypto on the OAuth2 client) — `oidcc` validates signatures against
whatever algorithm the provider's discovery document advertises, so this
needs no Keila-side configuration, but confirm your reverse proxy /
firewall allows Keila's outbound HTTPS to the issuer for JWKS fetches.

Do not disable PKCE on the kanidm client. Keila's OIDC routes use
`Oidcc.Plug.Authorize` / `Oidcc.Plug.AuthorizationCallback`, which use PKCE,
`state` and `nonce` by default; turning PKCE off on the IdP side removes a
layer of protection those plugs are relying on being present.

## Troubleshooting

**Provider skipped at boot.** Check the application log at startup for
`OIDC provider "<name>" is not configured and will be skipped` (missing
`ISSUER`/`CLIENT_ID`/`CLIENT_SECRET` — the message names which). Other
providers are unaffected. An unknown `_POLICY` or a leftover `_TENANT_*`
variable does not skip: it stops the boot, naming the variable.

**404 on the sign-in route for a provider.** The provider name in the URL
doesn't match a currently valid, enabled provider — either it isn't in
`KEILA_OIDC_PROVIDERS`, or it was dropped at boot per the previous point.
Check `KEILA_OIDC_PROVIDERS` and the boot log together.

**A specific user's sign-in is refused.** Match the log reason against the
table in "Provisioning and account linking" above.
`:not_entitled`/`:provisioning_disabled` mean the claim/gate configuration
or the IdP-side group membership needs fixing; `:email_exists` means the
account already exists under a different login path and needs manual
reconciliation, not a config change.

**Everyone is refused on one provider.** Most likely
`:provisioning_disabled` (an entitlement gate that's misconfigured or
unset), a `pushed` provider whose people were never pushed, or a scope map
on the IdP side that isn't actually including the claim Keila is asking for
(`_ENTITLEMENT_CLAIM`) — check
the ID token contents against what the configured claim name expects.
