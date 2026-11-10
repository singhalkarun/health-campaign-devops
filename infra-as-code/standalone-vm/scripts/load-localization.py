#!/usr/bin/env python3
"""Copy UI localization messages from a running HCM instance into this one.

v2.1 publishes no localization seed. This downloads the messages for the given modules from
a source instance (eGov's public demo by default), merges them and upserts them into the
target tenant through the target's localization API.

Merge order for each target locale: later sources override earlier ones (same code+module).

  download:  python3 -I load-localization.py download out.json
  upload:    HCM_USER=... HCM_PASSWORD=... python3 -I load-localization.py upload out.json https://<domain> <tenant>

Edit SOURCES / MODULES below to change what is copied.
"""
import json, os, sys, time, urllib.parse, urllib.request, base64

SRC = "https://health-demo.digit.org"
# target locale -> list of (source tenant, source locale), lowest priority first.
# The UIs append their localeRegion ("DEMO" in assets/deploy-assets.sh) to the language codes
# in StateInfo, so the target tenant's locales are <lang>_DEMO. eGov's tenant `mz` has the
# fullest set, `demo` its own overrides.
SOURCES = {
    "en_DEMO": [("mz", "en_MZ"), ("demo", "en_MZ"), ("demo", "en_DEMO")],
    "pt_DEMO": [("mz", "pt_MZ"), ("demo", "pt_MZ"), ("demo", "pt_DEMO")],
    "fr_DEMO": [("mz", "fr_MZ"), ("demo", "fr_MZ"), ("demo", "fr_DEMO")],
}
MODULES = """rainmaker-common rainmaker-hcm-common rainmaker-hcm-dss rainmaker-workbench rainmaker-mdms
rainmaker-campaignmanager rainmaker-microplanning rainmaker-dss rainmaker-common-masters rainmaker-core
rainmaker-hr rainmaker-schema rainmaker-workbench-hcm rainmaker-boundary-admin rainmaker-pgr
digit-ui digit-schema digit-workbench digit-privacy-policy digit-tenants
hcm-common hcm-checklist hcm-reports hcm-delivery hcm-member hcm-household hcm-login hcm-acknowledgement
hcm-beneficiary hcm-home hcm-forgot-password hcm-stock hcm-stock-reconciliation hcm-warehouse-details
hcm-closedhousehold hcm-inventory-selection hcm-inventory-details hcm-attendance hcm-dashboard
hcm-campaignmanager hcm-campaign-settings hcm-admin-schemas hcm-boundary-admin hcm-dss hcm-payments
hcm-microplanning""".split()


def post(url, body, headers=None, form=False):
    data = urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()
    h = {"Content-Type": "application/x-www-form-urlencoded" if form else "application/json"}
    h.update(headers or {})
    for attempt in range(30):
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=120))
        except urllib.error.HTTPError as e:
            if e.code == 429:  # the gateway rate-limits per client IP
                time.sleep(min(2 * (attempt + 1), 20))
                continue
            raise SystemExit(f"{url}: HTTP {e.code} {e.read()[:300]!r}")
        except Exception as e:
            if attempt >= 4:
                raise
            time.sleep(3)


def dedupe(msgs):
    out = {}
    for x in msgs:
        code = x["code"].strip()
        key = (x["module"].lower(), code.upper())
        prev = out.get(key)
        if prev is not None and code != code.upper() and prev["code"] == prev["code"].upper():
            code = prev["code"]
        out[key] = dict(x, code=code)
    return list(out.values())


def download(out):
    merged = {}
    for tloc, srcs in SOURCES.items():
        msgs = {}
        for tenant, loc in srcs:
            for m in MODULES:
                q = urllib.parse.urlencode({"tenantId": tenant, "locale": loc, "module": m})
                for x in post(f"{SRC}/localization/messages/v1/_search?{q}", {"RequestInfo": {}}).get("messages", []):
                    # The service trims codes and compares them case-insensitively, so " X", "x"
                    # and "X" collide in one upsert. Keep one per key, preferring the upper-case code.
                    code = x["code"].strip()
                    key = (x["module"].lower(), code.upper())
                    prev = msgs.get(key)
                    keep = code if prev is None or code == code.upper() or prev[1] != prev[1].upper() else prev[1]
                    msgs[key] = (x["module"], keep, x["message"])
        merged[tloc] = [{"module": m, "code": c, "message": v, "locale": tloc} for m, c, v in msgs.values()]
        print(f"{tloc}: {len(merged[tloc])} messages", flush=True)
    json.dump(merged, open(out, "w"), ensure_ascii=False)


def upload(path, base, tenant):
    data = json.load(open(path))
    data = {loc: dedupe(ms) for loc, ms in data.items()}
    # public.message.message is varchar(500); a few eGov texts are longer. Widen the column
    # (README 5.1) or they are skipped here.
    limit = int(os.environ.get("MAX_MESSAGE_LEN", "500"))
    for loc, ms in data.items():
        long_ = [x["code"] for x in ms if len(x["message"]) > limit]
        if long_:
            print(f"{loc}: skipping {len(long_)} messages longer than {limit} chars", flush=True)
            data[loc] = [x for x in ms if len(x["message"]) <= limit]
    tok = post(f"{base}/user/oauth/token",
               {"username": os.environ["HCM_USER"], "password": os.environ["HCM_PASSWORD"],
                "grant_type": "password", "scope": "read", "tenantId": tenant, "userType": "EMPLOYEE"},
               {"Authorization": "Basic " + base64.b64encode(b"egov-user-client:").decode()}, form=True)
    ri = {"apiId": "Rainmaker", "msgId": "1|en_IN", "authToken": tok["access_token"], "userInfo": tok["UserRequest"]}
    for loc, msgs in data.items():
        # one module per request: the upsert keys a request's messages by code alone
        by_module = {}
        for x in msgs:
            by_module.setdefault(x["module"], []).append(x)
        for mod_msgs in by_module.values():
            for i in range(0, len(mod_msgs), 1000):
                r = post(f"{base}/localization/messages/v1/_upsert",
                         {"RequestInfo": ri, "tenantId": tenant, "messages": mod_msgs[i:i + 1000]})
                if "messages" not in r:
                    raise SystemExit(f"upsert failed: {str(r)[:300]}")
        print(f"{loc}: upserted {len(msgs)}", flush=True)


if __name__ == "__main__":
    if sys.argv[1:2] == ["download"] and len(sys.argv) == 3:
        download(sys.argv[2])
    elif sys.argv[1:2] == ["upload"] and len(sys.argv) == 5:
        upload(*sys.argv[2:])
    else:
        raise SystemExit(__doc__)
