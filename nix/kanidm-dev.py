"""Provision the local kanidm realm that the OIDC suite and a dev sign-in both need.

Idempotent: every step is a create-or-ignore, so a warm realm is a no-op and a cold one converges.
"""

import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

WORK = os.environ["KEILA_KANIDM_WORK"]
URL = os.environ["KEILA_KANIDM_URL"]
KANIDMD = os.environ.get("KANIDMD", "kanidmd")
CLIENT_ID = os.environ.get("KEILA_KANIDM_CLIENT", "keila-merchant")
PROVIDER = os.environ.get("KEILA_KANIDM_PROVIDER", "merchant")
ORIGIN = os.environ.get("KEILA_ORIGIN", "http://localhost:4000")
PREFIX = os.environ.get("KEILA_KANIDM_PREFIX", "merchant")
SLUG = os.environ.get("KEILA_KANIDM_SLUG", "acme")
ROLE = os.environ.get("KEILA_KANIDM_ROLE", "admin")
PERSON = os.environ.get("KEILA_KANIDM_PERSON", "merchant_dev")
PASSWORD = os.environ.get("KEILA_KANIDM_PASSWORD", "keila-dev-password")

CTX = ssl.create_default_context(cafile=f"{WORK}/ca.pem")


def req(path, method="GET", body=None, tok=None):
    headers = {"content-type": "application/json"}
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(r, context=CTX) as resp:
        raw = resp.read()
        return resp.headers, (json.loads(raw) if raw else None)


EXISTS = r"attribute uniqueness|already exists|duplicate"
LAGGING = r"referentialintegrity|Uuid referenced not found"


def post_ok_if_exists(path, body, tok):
    """kanidm's name->uuid index lags on a cold realm, so referential errors are retried."""
    for _ in range(10):
        try:
            req(path, "POST", body, tok)
            return
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            if re.search(EXISTS, txt, re.I):
                return
            if re.search(LAGGING, txt, re.I):
                time.sleep(1)
                continue
            raise SystemExit(f"POST {path} failed ({e.code}): {txt}")
    raise SystemExit(f"POST {path} never settled")


def wait_ready(timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            req("/status")
            return
        except Exception:
            time.sleep(1)
    raise SystemExit(f"kanidmd at {URL} did not become ready")


def admin_token():
    out = subprocess.run(
        [KANIDMD, "recover-account", "idm_admin", "-c", f"{WORK}/server.toml"],
        capture_output=True,
        text=True,
    )
    m = re.search(r'new_password:\s*"([^"]+)"', out.stdout + out.stderr)
    if not m:
        raise SystemExit(f"could not recover idm_admin:\n{out.stdout}\n{out.stderr}")
    pw = m.group(1)
    with open(f"{WORK}/idm_admin.pw", "w") as f:
        os.chmod(f.name, 0o600)
        f.write(pw + "\n")

    headers, body = req(
        "/v1/auth",
        "POST",
        {"step": {"init2": {"username": "idm_admin", "issue": "token", "privileged": True}}},
    )
    sid = headers.get("x-kanidm-auth-session-id") or (body or {}).get("sessionid")
    if not sid:
        raise SystemExit(f"kanidm at {URL} issued no auth session id")

    def step(payload):
        r = urllib.request.Request(
            URL + "/v1/auth",
            data=json.dumps(payload).encode(),
            headers={"content-type": "application/json", "x-kanidm-auth-session-id": sid},
            method="POST",
        )
        with urllib.request.urlopen(r, context=CTX) as resp:
            return json.loads(resp.read())

    step({"step": {"begin": "password"}})
    tok = step({"step": {"cred": {"password": pw}}})["state"]["success"]
    return tok


def allow_passwords(tok):
    # PUT REPLACES; a POST would append. Without it a person cannot hold a password at all.
    req("/v1/group/idm_all_persons/_attr/credential_type_minimum", "PUT", ["any"], tok)
    for attr in ("authsession_expiry", "privilege_expiry"):
        req(f"/v1/group/idm_all_persons/_attr/{attr}", "PUT", ["28800"], tok)


def ensure_client(tok):
    callback = f"{ORIGIN}/auth/oidc/{PROVIDER}/callback"
    post_ok_if_exists(
        "/v1/oauth2/_basic",
        {
            "attrs": {
                "name": [CLIENT_ID],
                "displayname": ["Keila (merchant newsletter)"],
                "oauth2_rs_origin_landing": [ORIGIN],
                "oauth2_rs_origin": [callback],
            }
        },
        tok,
    )
    # `groups_spn` not `groups`: `groups` also emits a uuid per group, which the tenant_spn policy
    # cannot parse into a slug.
    post_ok_if_exists(
        f"/v1/oauth2/{CLIENT_ID}/_scopemap/idm_all_persons",
        ["openid", "email", "profile", "groups_spn"],
        tok,
    )
    _, secret = req(f"/v1/oauth2/{CLIENT_ID}/_basic_secret", tok=tok)
    if not secret:
        raise SystemExit(f"{CLIENT_ID} has no basic secret — was it created as a public client?")
    return secret


def ensure_merchant(tok):
    group = f"{PREFIX}.{SLUG}.{ROLE}"
    post_ok_if_exists(
        "/v1/person",
        {
            "attrs": {
                "name": [PERSON],
                "displayname": [f"{SLUG} {ROLE}"],
                "mail": [f"{PERSON}@example.test"],
            }
        },
        tok,
    )
    post_ok_if_exists("/v1/group", {"attrs": {"name": [group]}}, tok)
    post_ok_if_exists(f"/v1/group/{group}/_attr/member", [PERSON], tok)

    _, session = req(f"/v1/person/{PERSON}/_credential/_update", tok=tok)
    if not session:
        raise SystemExit(f"no credential-update session for {PERSON}")
    req("/v1/credential/_update", "POST", [{"password": PASSWORD}, session[0]], tok)
    req("/v1/credential/_commit", "POST", session[0], tok)
    return group


def main():
    wait_ready()
    tok = admin_token()
    allow_passwords(tok)
    secret = ensure_client(tok)
    group = ensure_merchant(tok)

    var = f"KEILA_OIDC_{PROVIDER.upper()}_"
    env_path = f"{WORK}/keila.env"
    with open(env_path, "w") as f:
        os.chmod(f.name, 0o600)
        f.write(
            "\n".join(
                [
                    f"KEILA_OIDC_PROVIDERS={PROVIDER}",
                    f"{var}ISSUER={URL}/oauth2/openid/{CLIENT_ID}",
                    f"{var}CLIENT_ID={CLIENT_ID}",
                    f"{var}CLIENT_SECRET={secret}",
                    f"{var}POLICY=tenant_spn",
                    f"{var}TENANT_PREFIX={PREFIX}",
                    f'{var}SCOPES="openid email profile groups_spn"',
                    f"{var}CACERTFILE={WORK}/ca.pem",
                    "",
                ]
            )
        )
    print(f"✓ keila CIAM ready at {URL}")
    print(f"  client {CLIENT_ID}; env at {env_path}")
    print(f"  sign in as {PERSON} / {PASSWORD} (in {group})")


if __name__ == "__main__":
    sys.exit(main())
