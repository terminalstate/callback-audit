{  # noqa: B018  (an Odoo manifest is a bare dict)
    "name": "Repro: Mercado Pago webhook answers 200 when the payment fetch fails",
    "summary": "Test-only module: runs Odoo's own Mercado Pago webhook against a fake Mercado Pago API.",
    "version": "1.0",
    "depends": ["payment_mercado_pago"],
    "license": "LGPL-3",
    "installable": True,
}
