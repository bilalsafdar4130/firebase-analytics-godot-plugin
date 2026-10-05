"""Tests for addons/mobile_services/tools/play_products.py.

    python3 -m unittest discover -s tests -p "test_play_products.py"

Google is replaced by a fake transport that answers like the Play Developer
API and records every call, so these check what the tool SENDS -- the shape of
a product Play is asked to create, and that nothing is written when nothing
should be -- without a key or a network.
"""
import io
import json
import os
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "addons", "mobile_services", "tools"))

import play_products  # noqa: E402

PACKAGE = "com.example.game"

CONFIG = """
[iap]
enabled = true

[iap.product.remove_ads]
type = "non_consumable"
entitlement = "remove_ads"

[iap.product.coins_small]
type = "consumable"
entitlement = ""            ; consumables grant nothing permanent
android_id = "com.example.game.coins_small"
"""

CATALOGUE = {
    "_readme": "comments are allowed",
    "products": {
        "remove_ads": {"title": "Remove Ads", "description": "No more banner.", "usd_price": "2.99"},
        "coins_small": {"title": "Coins", "description": "500 coins.", "usd_price": "0.99"},
    },
}

CONVERTED = {
    "convertedRegionPrices": {
        "US": {"regionCode": "US", "price": {"currencyCode": "USD", "units": "2", "nanos": 990000000}},
        "PK": {"regionCode": "PK", "price": {"currencyCode": "PKR", "units": "850"}},
    },
    "convertedOtherRegionsPrice": {
        "usdPrice": {"currencyCode": "USD", "units": "2", "nanos": 990000000},
        "eurPrice": {"currencyCode": "EUR", "units": "2", "nanos": 790000000},
    },
    "regionVersion": {"version": "2025/03"},
}


def existing(product_id, state="ACTIVE", extra_options=()):
    return {
        "packageName": PACKAGE,
        "productId": product_id,
        "listings": [{"languageCode": "en-US", "title": "Old", "description": "Old."}],
        "purchaseOptions": [{
            "purchaseOptionId": "buy",
            "state": state,
            "buyOption": {"legacyCompatible": True},
            "regionalPricingAndAvailabilityConfigs": [
                {"regionCode": "US", "price": {"currencyCode": "USD", "units": "1", "nanos": 990000000},
                 "availability": "AVAILABLE"},
            ],
        }] + list(extra_options),
    }


class FakePlay:
    """Answers like the Play Developer API. `products` is what Play has."""

    def __init__(self, products=None, fail=None):
        self.products = dict(products or {})
        self.fail = dict(fail or {})  # "METHOD path-fragment" -> [statuses, ...]
        self.calls = []

    def __call__(self, method, url, headers, body):
        path = url.split("/applications/", 1)[-1]
        payload = json.loads(body) if body and headers.get("Content-Type") == "application/json" else None
        self.calls.append((method, path, payload))
        for key, statuses in self.fail.items():
            want_method, fragment = key.split(" ", 1)
            if method == want_method and fragment in path and statuses:
                status = statuses.pop(0)
                return status, json.dumps({"error": {"message": f"fake {status}"}}).encode()
        if path.endswith("/edits") and method == "POST":
            return 200, b'{"id": "e1"}'
        if "/edits/e1/details" in path:
            return 200, b'{"defaultLanguage": "en-US"}'
        if "/edits/e1" in path and method == "DELETE":
            return 204, b""
        if "pricing:convertRegionPrices" in path:
            return 200, json.dumps(CONVERTED).encode()
        if ":batchUpdateStates" in path:
            product_id = path.split("/oneTimeProducts/")[1].split("/")[0]
            for option in self.products[product_id]["purchaseOptions"]:
                option["state"] = "ACTIVE"
            return 200, b"{}"
        if "/onetimeproducts/" in path and method == "PATCH":
            product_id = path.split("/onetimeproducts/")[1].split("?")[0]
            saved = json.loads(json.dumps(payload))
            for option in saved["purchaseOptions"]:
                option.setdefault("state", "DRAFT")
            self.products[product_id] = saved
            return 200, json.dumps(saved).encode()
        if "/oneTimeProducts/" in path and method == "GET":
            product_id = path.split("/oneTimeProducts/")[1]
            if product_id in self.products:
                return 200, json.dumps(self.products[product_id]).encode()
            return 404, b'{"error": {"message": "Product not found."}}'
        return 500, b'{"error": {"message": "unexpected call"}}'

    def writes(self):
        return [c for c in self.calls if c[0] in ("PATCH",) or ":batchUpdateStates" in c[1]]


class PlayProductsTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.config = os.path.join(self.dir.name, "mobile_services.cfg")
        self.catalogue = os.path.join(self.dir.name, "play_products.json")
        with open(self.config, "w") as handle:
            handle.write(CONFIG)
        self.write_catalogue(CATALOGUE)
        os.environ["PLAY_SERVICE_ACCOUNT_JSON"] = json.dumps(
            {"client_email": "sa@example.iam.gserviceaccount.com", "private_key": "unused"}
        )
        os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self._token = play_products.Play._access_token
        play_products.Play._access_token = lambda self: "token"

    def tearDown(self):
        play_products.Play._access_token = self._token
        os.environ.pop("PLAY_SERVICE_ACCOUNT_JSON", None)
        self.dir.cleanup()

    def write_catalogue(self, data):
        with open(self.catalogue, "w") as handle:
            json.dump(data, handle)

    def run_tool(self, mode, fake=None, dry_run=False):
        args = types.SimpleNamespace(
            package=PACKAGE, config=self.config, catalogue=self.catalogue,
            mode=mode, language="", dry_run=dry_run,
        )
        out = io.StringIO()
        code = play_products.run(args, transport=fake, out=out)
        return code, out.getvalue()

    # --- validate ---------------------------------------------------------------

    def test_config_is_read_with_ids_and_inline_comments(self):
        products = play_products.read_products(self.config)
        self.assertEqual(products["remove_ads"]["android_id"], "remove_ads")
        self.assertEqual(products["coins_small"]["android_id"], "com.example.game.coins_small")
        self.assertEqual(products["coins_small"]["entitlement"], "")

    def test_agreeing_files_validate(self):
        code, out = self.run_tool("validate")
        self.assertEqual(code, play_products.EXIT_OK, out)

    def test_a_product_missing_from_either_file_is_named(self):
        data = json.loads(json.dumps(CATALOGUE))
        del data["products"]["coins_small"]
        data["products"]["gems"] = {"title": "Gems", "description": "Gems.", "usd_price": "1.99"}
        self.write_catalogue(data)
        code, out = self.run_tool("validate")
        self.assertEqual(code, play_products.EXIT_INVALID)
        self.assertIn("coins_small: is in mobile_services.cfg but not in the catalogue", out)
        self.assertIn("gems: is in the catalogue but has no [iap.product.gems]", out)

    def test_listing_limits_and_prices_are_checked(self):
        data = json.loads(json.dumps(CATALOGUE))
        data["products"]["remove_ads"]["title"] = "x" * 56
        data["products"]["coins_small"]["usd_price"] = "0.999"
        self.write_catalogue(data)
        code, out = self.run_tool("validate")
        self.assertEqual(code, play_products.EXIT_INVALID)
        self.assertIn("title must be 1-55 characters", out)
        self.assertIn("usd_price must be a price", out)

    def test_money_has_no_float_rounding(self):
        self.assertEqual(play_products.money("2.99"), {"currencyCode": "USD", "units": "2", "nanos": 990000000})
        self.assertEqual(play_products.money("10"), {"currencyCode": "USD", "units": "10", "nanos": 0})

    # --- create -------------------------------------------------------------------

    def test_missing_products_are_created_and_put_on_sale(self):
        fake = FakePlay()
        code, out = self.run_tool("create", fake)
        self.assertEqual(code, play_products.EXIT_OK, out)
        patches = [c for c in fake.calls if c[0] == "PATCH"]
        self.assertEqual(len(patches), 2)
        method, path, body = patches[0]
        self.assertIn("allowMissing=true", path)
        self.assertIn("regionsVersion.version=2025%2F03", path)
        self.assertEqual(body["listings"][0], {
            "languageCode": "en-US", "title": "Remove Ads", "description": "No more banner.",
        })
        option = body["purchaseOptions"][0]
        self.assertEqual(option["purchaseOptionId"], "buy")
        self.assertTrue(option["buyOption"]["legacyCompatible"])
        self.assertEqual({r["regionCode"] for r in option["regionalPricingAndAvailabilityConfigs"]}, {"US", "PK"})
        self.assertEqual(option["newRegionsConfig"]["availability"], "AVAILABLE")
        self.assertIn("onetimeproducts/com.example.game.coins_small", patches[1][1])
        self.assertEqual(fake.products["remove_ads"]["purchaseOptions"][0]["state"], "ACTIVE")
        self.assertEqual(fake.products["com.example.game.coins_small"]["purchaseOptions"][0]["state"], "ACTIVE")
        self.assertTrue(any("/edits/e1" in c[1] and c[0] == "DELETE" for c in fake.calls),
                        "the edit used to read the language is thrown away")

    def test_an_active_product_is_never_changed_by_create(self):
        fake = FakePlay({"remove_ads": existing("remove_ads"),
                         "com.example.game.coins_small": existing("com.example.game.coins_small")})
        code, out = self.run_tool("create", fake)
        self.assertEqual(code, play_products.EXIT_OK, out)
        self.assertEqual(fake.writes(), [])
        self.assertIn("already ACTIVE, US $1.99 (not changed)", out)

    def test_a_draft_left_by_an_earlier_run_is_activated(self):
        fake = FakePlay({"remove_ads": existing("remove_ads", state="DRAFT"),
                         "com.example.game.coins_small": existing("com.example.game.coins_small")})
        code, out = self.run_tool("create", fake)
        self.assertEqual(code, play_products.EXIT_OK, out)
        self.assertEqual([c[0] for c in fake.writes()], ["POST"])
        self.assertEqual(fake.products["remove_ads"]["purchaseOptions"][0]["state"], "ACTIVE")

    def test_a_product_taken_off_sale_by_hand_is_left_alone(self):
        fake = FakePlay({"remove_ads": existing("remove_ads", state="INACTIVE"),
                         "com.example.game.coins_small": existing("com.example.game.coins_small")})
        code, out = self.run_tool("create", fake)
        self.assertEqual(code, play_products.EXIT_OK, out)
        self.assertEqual(fake.writes(), [])
        self.assertIn("INACTIVE: left alone", out)

    def test_dry_run_writes_nothing(self):
        fake = FakePlay()
        code, out = self.run_tool("create", fake, dry_run=True)
        self.assertEqual(code, play_products.EXIT_OK, out)
        self.assertEqual(fake.writes(), [])
        self.assertIn("[dry run] PATCH", out)

    # --- sync ---------------------------------------------------------------------

    def test_sync_updates_the_managed_option_and_keeps_the_others(self):
        promo = {"purchaseOptionId": "promo", "state": "ACTIVE", "buyOption": {}}
        fake = FakePlay({"remove_ads": existing("remove_ads", extra_options=[promo]),
                         "com.example.game.coins_small": existing("com.example.game.coins_small", "INACTIVE")})
        code, out = self.run_tool("sync", fake)
        self.assertEqual(code, play_products.EXIT_OK, out)
        body = [c for c in fake.calls if c[0] == "PATCH" and "remove_ads" in c[1]][0][2]
        self.assertIn("allowMissing=false", [c for c in fake.calls if c[0] == "PATCH"][0][1])
        ids = [o["purchaseOptionId"] for o in body["purchaseOptions"]]
        self.assertEqual(ids, ["buy", "promo"], "the hand-made option is kept")
        self.assertNotIn("state", body["purchaseOptions"][1], "output-only fields are not sent back")
        self.assertEqual(body["listings"][0]["title"], "Remove Ads")
        self.assertEqual(len(body["purchaseOptions"][0]["regionalPricingAndAvailabilityConfigs"]), 2)
        self.assertEqual(fake.products["com.example.game.coins_small"]["purchaseOptions"][0]["state"], "ACTIVE",
                         "sync puts a product taken off sale back on sale")

    # --- failures ---------------------------------------------------------------------

    def test_a_permission_refusal_says_which_permission(self):
        fake = FakePlay(fail={"GET oneTimeProducts": [403, 403]})
        code, out = self.run_tool("create", fake)
        self.assertEqual(code, play_products.EXIT_FAILED)
        self.assertIn("Manage store presence", out)
        self.assertEqual(fake.writes(), [])

    def test_a_server_error_is_retried(self):
        fake = FakePlay(fail={"POST pricing:convertRegionPrices": [503]})
        code, out = self.run_tool("create", fake)
        self.assertEqual(code, play_products.EXIT_OK, out)

    def test_no_key_is_a_clear_failure(self):
        os.environ.pop("PLAY_SERVICE_ACCOUNT_JSON")
        code, out = self.run_tool("create", FakePlay())
        self.assertEqual(code, play_products.EXIT_FAILED)
        self.assertIn("PLAY_SERVICE_ACCOUNT_JSON is not set", out)

    def test_check_reports_without_writing(self):
        fake = FakePlay({"remove_ads": existing("remove_ads")})
        code, out = self.run_tool("check", fake)
        self.assertEqual(code, play_products.EXIT_OK, out)
        self.assertEqual(fake.writes(), [])
        self.assertIn("remove_ads (remove_ads): ACTIVE on Play, US $1.99", out)
        self.assertIn("MISSING on Play", out)


if __name__ == "__main__":
    unittest.main()
