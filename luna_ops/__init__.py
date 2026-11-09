"""Shared clients for the services every project uses: Gmail (mail), Cloudflare R2 (r2) and D1 (d1).

Credentials come from the environment first, then ~/.config/luna-ops/ops.env (LUNA_OPS_ENV overrides
the path), so a project that already loads its own .env keeps working unchanged. Never print them.

    from luna_ops import mail, r2
    from luna_ops.d1 import D1
"""
__version__ = '0.2.0'
