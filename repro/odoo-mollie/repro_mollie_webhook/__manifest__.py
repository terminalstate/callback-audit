{  # noqa: B018  (an Odoo manifest is a bare dict)
    "name": "Repro: Mollie webhook answers 200 when the status fetch fails",
    "summary": "Test-only module: runs Odoo's own Mollie webhook against a fake Mollie API.",
    "version": "1.0",
    "depends": ["payment_mollie"],
    "license": "LGPL-3",
    "installable": True,
}
