"""callback-audit: a read-only audit of webhook/callback delivery.

Answers one question about a payment system: where do payments stop short of a
terminal state, and at which of the seven stations between the provider and your
database does the callback get lost?

Everything here reads exports (CSV, access logs, application logs) and prints a
report. Nothing connects to a database, nothing writes, nothing calls the network.
"""

__version__ = "0.2.0"
