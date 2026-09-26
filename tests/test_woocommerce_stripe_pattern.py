"""Real-world wording: woocommerce-gateway-stripe (v11.0.0) logs validation failures as
'Webhook validation failed (signature_mismatch)'. The default signature pattern must match it."""

import re

from callback_audit.cli import DEFAULT_PATTERNS


def test_default_pattern_matches_woocommerce_stripe_wording():
    pat = re.compile(DEFAULT_PATTERNS["signature"], re.IGNORECASE)
    assert pat.search("Webhook validation failed (signature_mismatch)")
    assert pat.search("Webhook validation failed (signature_invalid)")


def test_default_pattern_still_matches_space_wording():
    pat = re.compile(DEFAULT_PATTERNS["signature"], re.IGNORECASE)
    assert pat.search("signature mismatch")
    assert pat.search("invalid signature")
