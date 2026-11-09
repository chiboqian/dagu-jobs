"""Settings lookup: os.environ, then an env file (`env_file` if given), then the shared ops.env."""
from __future__ import annotations

import os
from pathlib import Path


def ops_env() -> Path:
    return Path(os.getenv('LUNA_OPS_ENV', '~/.config/luna-ops/ops.env')).expanduser()


def read_env(path: Path | str) -> dict[str, str]:
    """KEY=VALUE lines (optional `export `, quotes, comments); the first of a repeated key wins."""
    out: dict[str, str] = {}
    p = Path(path).expanduser()
    if not p.exists():
        return out
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        if line.startswith('export '):
            line = line[len('export '):]
        k, v = line.split('=', 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
            v = v[1:-1]
        out.setdefault(k.strip(), v)
    return out


def setting(name: str, env_file: Path | str | None = None) -> str | None:
    if os.environ.get(name):
        return os.environ[name]
    for f in ([env_file] if env_file else []) + [ops_env()]:
        v = read_env(f).get(name)
        if v:
            return v
    return None


def require(names: tuple[str, ...], env_file: Path | str | None = None) -> dict[str, str]:
    """The named settings, or RuntimeError naming the missing ones (never their values)."""
    got = {n: setting(n, env_file) for n in names}
    missing = [n for n, v in got.items() if not v]
    if missing:
        where = ', '.join(str(x) for x in ([env_file] if env_file else []) + [ops_env()])
        raise RuntimeError(f'missing {", ".join(missing)} (environment, {where})')
    return got  # type: ignore[return-value]
