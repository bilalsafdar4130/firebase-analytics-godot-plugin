#!/usr/bin/env python3
"""Creates a game's in-app products in Google Play, from files in the game's repo.

Every product a game sells is declared twice: once in `mobile_services.cfg`
(`[iap.product.<name>]` -- what the game asks the SDK to buy) and once in the
Play Console (what Google actually sells). If the two disagree -- a typo in an
id, a product never activated -- the BUY button silently never appears. This
script makes the repository the single source of both: it reads the game's
config and a small catalogue file with the titles, descriptions and prices, and
creates exactly those products on Play.

    play_products.py --package com.example.game \\
        --config mobile_services.cfg --catalogue store/play_products.json \\
        --mode create

MODES
    validate  Offline. Checks the catalogue against mobile_services.cfg. No key needed.
    check     Reads what Play has for each product and prints it. Changes nothing.
    create    Creates every product Play does not have yet, and puts it on sale.
              A product that already exists is left exactly as it is -- a price
              changed by hand in the Play Console is never overwritten. (The
              default, and what the games' workflow runs on every merge.)
    sync      Like create, and also rewrites the title, description and price of
              every existing product to match the catalogue, and puts back on
              sale any product that was taken off. Run it by hand, on purpose.

Add --dry-run to check/create/sync to print what would be sent without sending.

THE CATALOGUE FILE (JSON), one entry per `[iap.product.<name>]` section:

    {
      "products": {
        "remove_ads": {
          "title": "Remove Ads",                       <= 55 characters
          "description": "Removes the banner, for good.",   <= 200 characters
          "usd_price": "2.99"
        }
      }
    }

The Play product id is the section's `android_id` in mobile_services.cfg (the
section name when there is none). `usd_price` is converted by Google into every
country's own currency, the same conversion the Play Console's "Set prices"
button does -- including tax where prices include tax.

WHAT IT CREATES. A one-time product (Play Billing 8's model) with one "buy"
purchase option marked backwards compatible, available in every country Play
sells in and in any country it adds later. Consumable or not is not a Play
Console setting -- the SDK consumes consumables itself after granting them.
Subscriptions are not created here; make those in the Play Console.

PERMISSIONS. The service account (the PLAY_SERVICE_ACCOUNT_JSON secret the
games already upload builds with) needs, in Play Console -> Users and
permissions, for the app: "View app information (read-only)" and "Manage store
presence". Uploading builds needs neither, so an account that publishes fine
can still be refused here -- the error says so.

Standard library and the `openssl` CLI only (both on every GitHub runner).
Never prints a key or a token.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"

# The one purchase option this script manages on each product. Products made in
# the Play Console have their own option ids; for those, the backwards
# compatible "buy" option is the one updated instead (see `_managed_option`).
OPTION_ID = "buy"

# Play's own limits for a one-time product listing.
TITLE_MAX = 55
DESCRIPTION_MAX = 200
PRODUCT_ID = re.compile(r"^[a-z0-9][a-z0-9_.]*$")
PRICE = re.compile(r"^\d+(\.\d{1,2})?$")

SELLABLE_TYPES = ("consumable", "non_consumable")
EXIT_OK, EXIT_FAILED, EXIT_INVALID = 0, 1, 2


class PlayError(Exception):
    """A refusal from the Play Developer API, with what to do about it."""

    def __init__(self, status, message, hint=""):
        super().__init__(message)
        self.status = status
        self.message = message
        self.hint = hint

    def __str__(self):
        text = f"HTTP {self.status}: {self.message}" if self.status else self.message
        return f"{text}\n    -> {self.hint}" if self.hint else text


# --- Reading the game's files ----------------------------------------------


QUOTED = re.compile(r'^"((?:[^"\\]|\\.)*)"')


def _parse_value(raw):
    """One Godot ConfigFile value: a quoted string, a bool, a number, or an
    array, with any `; comment` after it dropped. Anything else comes back as
    the raw text, which is fine here: only the [iap.product.*] keys are ever
    read, and those are all strings."""
    raw = raw.strip()
    quoted = QUOTED.match(raw)
    if quoted:
        return json.loads(quoted.group(0))
    raw = raw.split(";", 1)[0].strip()
    if raw in ("true", "false"):
        return raw == "true"
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def read_products(config_path):
    """The `[iap.product.<name>]` sections of a mobile_services.cfg, as
    {name: {"type", "entitlement", "android_id"}}."""
    products = {}
    section = None
    with open(config_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith(";") or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                if section.startswith("iap.product."):
                    products.setdefault(section[len("iap.product."):], {})
                continue
            if section is None or not section.startswith("iap.product.") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            products[section[len("iap.product."):]][key.strip()] = _parse_value(value)
    for name, product in products.items():
        product.setdefault("type", "")
        product.setdefault("entitlement", "")
        product["android_id"] = str(product.get("android_id") or name)
    return products


def read_catalogue(catalogue_path):
    with open(catalogue_path, encoding="utf-8") as handle:
        data = json.load(handle)
    products = data.get("products")
    if not isinstance(products, dict):
        raise ValueError(f'{catalogue_path} has no "products" object')
    return data, products


def validate(config_products, catalogue):
    """Every problem that would stop a product being sold, as sentences.
    Empty when the two files agree and every entry is one Play will accept."""
    problems = []
    for name, product in sorted(config_products.items()):
        kind = product["type"]
        if kind == "subscription":
            if name in catalogue:
                problems.append(
                    f"{name}: is a subscription; create it in the Play Console (this "
                    "tool makes one-time products only) and remove it from the catalogue"
                )
            continue
        if kind not in SELLABLE_TYPES:
            problems.append(f"{name}: unknown type {kind!r} in mobile_services.cfg")
            continue
        if name not in catalogue:
            problems.append(
                f"{name}: is in mobile_services.cfg but not in the catalogue, so it "
                "would never be created on Play and its BUY button would never appear"
            )
    for name, entry in sorted(catalogue.items()):
        if name.startswith("_"):
            continue
        if name not in config_products:
            problems.append(
                f"{name}: is in the catalogue but has no [iap.product.{name}] section "
                "in mobile_services.cfg, so the game could never sell it"
            )
            continue
        if not isinstance(entry, dict):
            problems.append(f"{name}: catalogue entry must be an object")
            continue
        product_id = config_products[name]["android_id"]
        if not PRODUCT_ID.match(product_id):
            problems.append(
                f"{name}: Play product id {product_id!r} must start with a lowercase "
                "letter or digit and use only a-z, 0-9, '_' and '.'"
            )
        title = str(entry.get("title", ""))
        description = str(entry.get("description", ""))
        price = str(entry.get("usd_price", ""))
        if not 0 < len(title) <= TITLE_MAX:
            problems.append(f"{name}: title must be 1-{TITLE_MAX} characters (is {len(title)})")
        if not 0 < len(description) <= DESCRIPTION_MAX:
            problems.append(
                f"{name}: description must be 1-{DESCRIPTION_MAX} characters (is {len(description)})"
            )
        if not PRICE.match(price) or float(price) <= 0:
            problems.append(f'{name}: usd_price must be a price like "2.99" (is {price!r})')
    return problems


def money(usd_price):
    """ "2.99" -> Play's Money object, without a float rounding through it."""
    units, _, cents = usd_price.partition(".")
    return {
        "currencyCode": "USD",
        "units": str(int(units)),
        "nanos": int((cents + "00")[:2]) * 10_000_000,
    }


# --- Talking to Play ---------------------------------------------------------


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class Play:
    """The handful of Play Developer API calls this script needs, with retries
    for the failures that are worth retrying and plain words for the rest."""

    def __init__(self, package, service_account, transport=None, dry_run=False, out=None):
        self.package = package
        self.account = service_account
        self.dry_run = dry_run
        self.out = out or sys.stdout
        self._transport = transport or self._urllib
        self._token = None

    # -- HTTP --

    @staticmethod
    def _urllib(method, url, headers, body):
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def _call(self, method, url, body=None, form=None, auth=True, write=False):
        if write and self.dry_run:
            print(f"    [dry run] {method} {url.replace(API, '')}", file=self.out)
            return {}
        headers = {}
        data = None
        if auth:
            headers["Authorization"] = "Bearer " + self._access_token()
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        last = None
        for attempt in range(4):
            try:
                status, raw = self._transport(method, url, headers, data)
            except (urllib.error.URLError, OSError, TimeoutError) as error:
                last = PlayError(0, f"could not reach Google ({error})",
                                 "a network problem on the runner; re-run the workflow")
            else:
                if 200 <= status < 300:
                    return json.loads(raw) if raw else {}
                last = self._explain(status, raw)
                if status not in (429, 500, 502, 503, 504):
                    raise last
            time.sleep(2 ** attempt if self._transport is self._urllib else 0)
        raise last

    def _explain(self, status, raw):
        try:
            detail = json.loads(raw).get("error", {})
        except (ValueError, AttributeError):
            detail = {}
        message = str(detail.get("message") or (raw or b"").decode(errors="replace")[:300])
        lower = message.lower()
        hint = ""
        if status == 401:
            hint = ("PLAY_SERVICE_ACCOUNT_JSON was refused. Check the secret holds the whole "
                    "JSON key of a service account that still exists.")
        elif status == 403 and ("has not been used" in lower or "disabled" in lower):
            hint = ("Enable the 'Google Play Android Developer API' in the Google Cloud "
                    "project the service account belongs to, wait a few minutes, re-run.")
        elif status == 403:
            hint = (f"The service account {self.account.get('client_email', '')} may upload "
                    "builds but may not manage products. Play Console -> Users and "
                    "permissions -> that account -> App permissions -> this app -> tick "
                    "'View app information (read-only)' and 'Manage store presence', "
                    "save, then re-run (it can take a few minutes to apply).")
        elif status == 404 and "package" in lower:
            hint = (f"Play has no app {self.package} this account can see. Check the "
                    "package name, and that the service account is invited to this app.")
        elif "merchant" in lower or "payments profile" in lower:
            hint = ("Paid products need a payments profile linked to the developer account: "
                    "Play Console -> Setup -> Payments profile.")
        elif "billing" in lower and "permission" in lower:
            hint = ("Play only allows products once a build that uses Play Billing has been "
                    "uploaded. Let the 'Publish to Play' workflow upload one, then re-run.")
        elif status == 429:
            hint = "Play's rate limit; wait a minute and re-run."
        return PlayError(status, message, hint)

    def _access_token(self):
        if self._token:
            return self._token
        now = int(time.time())
        token_uri = self.account.get("token_uri", "https://oauth2.googleapis.com/token")
        header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
        claims = _b64url(json.dumps({
            "iss": self.account["client_email"], "scope": SCOPE, "aud": token_uri,
            "iat": now, "exp": now + 600,
        }).encode())
        unsigned = f"{header}.{claims}".encode()
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as key:
            os.chmod(key.name, 0o600)
            key.write(self.account["private_key"])
        try:
            signature = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", key.name],
                input=unsigned, capture_output=True, check=True,
            ).stdout
        except subprocess.CalledProcessError:
            raise PlayError(0, "could not sign with the service account key",
                            "PLAY_SERVICE_ACCOUNT_JSON's private_key is damaged; "
                            "paste the whole JSON key into the secret again") from None
        finally:
            os.remove(key.name)
        reply = self._call("POST", token_uri, auth=False, form={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": f"{header}.{claims}.{_b64url(signature)}",
        })
        self._token = reply["access_token"]
        return self._token

    # -- The API --

    def default_language(self):
        """The app's default listing language, which a product's listing must
        include. Read through a throwaway edit, which is deleted again."""
        base = f"{API}/{self.package}/edits"
        edit = self._call("POST", base, body={})["id"]
        try:
            return self._call("GET", f"{base}/{edit}/details").get("defaultLanguage", "")
        finally:
            try:
                self._call("DELETE", f"{base}/{edit}")
            except PlayError:
                pass

    def get_product(self, product_id):
        """The product, or None when Play has no product with this id. (An app
        that does not exist at all has already failed at `default_language`.)"""
        try:
            return self._call(
                "GET", f"{API}/{self.package}/oneTimeProducts/{urllib.parse.quote(product_id)}"
            )
        except PlayError as error:
            if error.status == 404:
                return None
            raise

    def convert_price(self, usd_price):
        return self._call(
            "POST", f"{API}/{self.package}/pricing:convertRegionPrices",
            body={"price": money(usd_price)},
        )

    def upsert(self, product, regions_version, create):
        query = urllib.parse.urlencode({
            "allowMissing": "true" if create else "false",
            "regionsVersion.version": regions_version,
            "updateMask": "listings,purchaseOptions",
        })
        product_id = urllib.parse.quote(product["productId"])
        return self._call(
            "PATCH", f"{API}/{self.package}/onetimeproducts/{product_id}?{query}",
            body=product, write=True,
        )

    def activate(self, product_id, option_id):
        return self._call(
            "POST",
            f"{API}/{self.package}/oneTimeProducts/{urllib.parse.quote(product_id)}"
            "/purchaseOptions:batchUpdateStates",
            body={"requests": [{"activatePurchaseOptionRequest": {
                "packageName": self.package, "productId": product_id,
                "purchaseOptionId": option_id,
            }}]},
            write=True,
        )


# --- Building a product --------------------------------------------------------


def _managed_option(existing):
    """The purchase option this script owns on an existing product: its own
    "buy" option, else the backwards compatible buy option the Play Console
    made, else the first buy option. None if there is no buy option at all."""
    options = [o for o in existing.get("purchaseOptions", []) if "buyOption" in o]
    for option in options:
        if option.get("purchaseOptionId") == OPTION_ID:
            return option
    for option in options:
        if option["buyOption"].get("legacyCompatible"):
            return option
    return options[0] if options else None


def build_product(package, product_id, entry, language, converted, existing=None):
    """The OneTimeProduct to send: one listing, and the managed purchase option
    priced in every region from Google's own conversion of the USD price.
    Options on an existing product other than the managed one are kept as
    they are."""
    regional = [
        {"regionCode": region, "price": quote["price"], "availability": "AVAILABLE"}
        for region, quote in sorted(converted.get("convertedRegionPrices", {}).items())
    ]
    other = converted.get("convertedOtherRegionsPrice", {})
    priced = {
        "regionalPricingAndAvailabilityConfigs": regional,
        "newRegionsConfig": {
            "usdPrice": other.get("usdPrice", money(entry["usd_price"])),
            "eurPrice": other.get("eurPrice"),
            "availability": "AVAILABLE",
        },
    }
    options = []
    if existing:
        managed = _managed_option(existing)
        for option in existing.get("purchaseOptions", []):
            option = {k: v for k, v in option.items() if k != "state"}
            if managed is not None and option.get("purchaseOptionId") == managed.get("purchaseOptionId"):
                option.update(priced)
            options.append(option)
        if managed is None:
            options.append(dict(_new_option(), **priced))
    else:
        options.append(dict(_new_option(), **priced))
    listings = [
        l for l in (existing or {}).get("listings", []) if l.get("languageCode") != language
    ]
    listings.insert(0, {
        "languageCode": language,
        "title": entry["title"],
        "description": entry["description"],
    })
    return {
        "packageName": package,
        "productId": product_id,
        "listings": listings,
        "purchaseOptions": options,
    }


def _new_option():
    return {
        "purchaseOptionId": OPTION_ID,
        # The option Play Billing returns for a product when the game passes no
        # offer token, and what an older Billing Library sells.
        "buyOption": {"legacyCompatible": True, "multiQuantityEnabled": False},
    }


def _price_of(product):
    """ "US $2.99" from a product as Play returns it, or "" when it has no US price."""
    option = _managed_option(product) or {}
    for config in option.get("regionalPricingAndAvailabilityConfigs", []):
        if config.get("regionCode") == "US":
            price = config.get("price", {})
            cents = round(int(price.get("nanos", 0)) / 10_000_000)
            return f"US ${int(price.get('units', 0))}.{cents:02d}"
    return ""


def _state_of(product):
    option = _managed_option(product) or {}
    return str(option.get("state", "UNKNOWN"))


# --- The run ---------------------------------------------------------------------


def run(args, transport=None, out=None):
    out = out or sys.stdout
    try:
        config_products = read_products(args.config)
        data, catalogue = read_catalogue(args.catalogue)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=out)
        return EXIT_INVALID
    problems = validate(config_products, catalogue)
    if problems:
        print("The catalogue and mobile_services.cfg disagree:", file=out)
        for problem in problems:
            print(f"  - {problem}", file=out)
        return EXIT_INVALID
    names = [n for n in catalogue if not n.startswith("_")]
    print(f"{len(names)} product(s) in the catalogue agree with mobile_services.cfg.", file=out)
    if args.mode == "validate":
        return EXIT_OK

    raw_key = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()
    if not raw_key:
        print("ERROR: PLAY_SERVICE_ACCOUNT_JSON is not set. In a workflow, pass the "
              "repository secret of the same name.", file=out)
        return EXIT_FAILED
    try:
        account = json.loads(raw_key)
        account["client_email"], account["private_key"]
    except (ValueError, KeyError, TypeError):
        print("ERROR: PLAY_SERVICE_ACCOUNT_JSON is not a service account JSON key "
              "(it needs client_email and private_key).", file=out)
        return EXIT_FAILED

    play = Play(args.package, account, transport=transport, dry_run=args.dry_run, out=out)
    try:
        # Asked even when the language is given: it is also the check that the
        # app exists and this account can see it, before any product is touched.
        app_language = play.default_language()
        language = args.language or data.get("language") or app_language or "en-US"
    except PlayError as error:
        print(f"ERROR: could not read the app from Play.\n  {error}", file=out)
        return EXIT_FAILED
    print(f"App {args.package}, listing language {language}, mode {args.mode}"
          f"{' (dry run)' if args.dry_run else ''}.", file=out)

    rows = []
    failed = 0
    for name in names:
        entry = catalogue[name]
        product_id = config_products[name]["android_id"]
        row = {
            "name": name, "id": product_id, "type": config_products[name]["type"],
            "price": f"US ${entry['usd_price']}", "result": "",
        }
        try:
            row["result"] = _one(play, args.mode, product_id, entry, language)
        except PlayError as error:
            failed += 1
            row["result"] = f"FAILED: {error.message}"
            print(f"  {name} ({product_id}): FAILED\n    {error}", file=out)
        else:
            print(f"  {name} ({product_id}): {row['result']}", file=out)
        rows.append(row)

    _summary(args, rows, failed)
    if failed:
        print(f"{failed} product(s) failed; the rest are as listed above.", file=out)
        return EXIT_FAILED
    return EXIT_OK


def _one(play, mode, product_id, entry, language):
    """One product, in one mode. Returns the line to report for it."""
    existing = play.get_product(product_id)
    if mode == "check":
        if existing is None:
            return "MISSING on Play (run the workflow in create mode)"
        return f"{_state_of(existing)} on Play, {_price_of(existing) or 'no US price'}"

    if existing is not None and mode == "create":
        state = _state_of(existing)
        if state == "DRAFT":
            # Created by an earlier run that stopped before activating it.
            play.activate(product_id, _managed_option(existing)["purchaseOptionId"])
            return f"existed as a draft; now ACTIVE, {_price_of(existing)}"
        if state != "ACTIVE":
            return (f"exists, {state}: left alone (taken off sale by hand?). "
                    "Run in sync mode to put it back on sale.")
        return f"already ACTIVE, {_price_of(existing)} (not changed)"

    converted = play.convert_price(entry["usd_price"])
    version = str(converted.get("regionVersion", {}).get("version", ""))
    if not version and not play.dry_run:
        raise PlayError(0, "Play's price conversion returned no regions version")
    product = build_product(play.package, product_id, entry, language, converted, existing)
    saved = play.upsert(product, version, create=existing is None)
    option = _managed_option(saved or product) or {}
    option_id = option.get("purchaseOptionId", OPTION_ID)
    if str(option.get("state", "DRAFT")) != "ACTIVE":
        play.activate(product_id, option_id)
    regions = len(converted.get("convertedRegionPrices", {}))
    verb = "created" if existing is None else "updated"
    return f"{verb} and ACTIVE at US ${entry['usd_price']} ({regions} countries priced by Google)"


def _summary(args, rows, failed):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    lines = [
        f"## Play products: {args.package} ({args.mode}{', dry run' if args.dry_run else ''})",
        "",
        "| Product | Play id | Kind | Price | Result |",
        "|---|---|---|---|---|",
    ]
    for row in rows:
        result = row["result"].replace("|", "/")
        lines.append(f"| {row['name']} | `{row['id']}` | {row['type']} | {row['price']} | {result} |")
    if failed:
        lines += ["", f"**{failed} product(s) failed.** The log above has Google's reason "
                  "and what to change for each."]
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--package", required=True, help="the app's package name")
    parser.add_argument("--config", default="mobile_services.cfg")
    parser.add_argument("--catalogue", default="store/play_products.json")
    parser.add_argument("--mode", default="create",
                        choices=["validate", "check", "create", "sync"])
    parser.add_argument("--language", default="",
                        help="listing language (default: the app's own default language)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print what would be changed; change nothing")
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
