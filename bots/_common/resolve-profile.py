#!/usr/bin/env python3
"""resolve-profile.py <repo_dir> <repo_full_name>

Bestimmt für einen PR das Test-Profil + die aktiven Checks — in drei Stufen:
  1. .codemole.yml im Repo  -> exakt das nutzen
  2. sonst: Marker-Erkennung -> Profil automatisch
  3. universell (secret-scan, ai-review) laufen immer mit

Gibt EINE JSON-Zeile aus:
  {"profile","source","checks":[...],"disabled":[...],"ignore":[...],"options":{...}}
source = "auto" | "<config-dateiname>"
"""
import sys
import os
import json

try:
    import yaml
except ImportError:
    yaml = None

# Profil -> Check-Bündel (universell kommt immer dazu)
PROFILES = {
    "ha-config":    ["yamllint", "ha-validate", "includes", "diff-size"],
    "ha-component": ["python-syntax", "manifest", "hacs", "translations", "diff-size"],
    "aem-eds":      ["eslint", "aem-block-validator", "visual", "diff-size"],
    "generic":      ["diff-size"],
}
UNIVERSAL = ["secret-scan", "ai-review"]
CONFIG_NAMES = (".codemole.yml", ".codemole.yaml",
                ".github/codemole.yml", ".github/codemole.yaml")


def detect(repo_dir):
    """Marker-basierte Profil-Erkennung (deterministisch, spezifischstes gewinnt)."""
    def has(*names):
        return any(os.path.exists(os.path.join(repo_dir, n)) for n in names)
    # Config-Repo gewinnt VOR custom_components (ein HA-Config-Repo kann beides haben).
    if has("configuration.yaml", "automations.yaml", "scripts.yaml"):
        return "ha-config"
    # Standalone-Custom-Component (kein configuration.yaml, aber Component-Marker).
    if os.path.isdir(os.path.join(repo_dir, "custom_components")) or has("manifest.json", "hacs.json"):
        return "ha-component"
    if os.path.isdir(os.path.join(repo_dir, "blocks")) and has("package.json"):
        return "aem-eds"
    return "generic"


def load_config(repo_dir):
    if not yaml:
        return None, None
    for name in CONFIG_NAMES:
        p = os.path.join(repo_dir, name)
        if os.path.isfile(p):
            try:
                with open(p, encoding="utf-8") as f:
                    return (yaml.safe_load(f) or {}), name
            except Exception:
                return {}, name  # vorhanden aber kaputt -> leeres Override, Quelle bleibt sichtbar
    return None, None


def main():
    repo_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    cfg, cfgfile = load_config(repo_dir)

    if cfg is not None:
        source = cfgfile
        if cfg.get("checks"):
            allow = list(cfg["checks"])           # explizite Allowlist
            checks = list(allow)
            profile = cfg.get("profile") or "custom"
        else:
            allow = []
            profile = cfg.get("profile") or detect(repo_dir)
            checks = PROFILES.get(profile, PROFILES["generic"]) + UNIVERSAL
        disabled = cfg.get("disable") or []
        ignore = cfg.get("ignore") or []
        options = {k: v for k, v in cfg.items()
                   if k not in ("profile", "checks", "disable", "ignore")}
    else:
        profile = detect(repo_dir)
        source = "auto"
        allow = []
        checks = PROFILES.get(profile, PROFILES["generic"]) + UNIVERSAL
        disabled, ignore, options = [], [], {}

    checks = [c for c in checks if c not in disabled]
    print(json.dumps({
        "profile": profile, "source": source, "checks": checks,
        "allow": allow, "disabled": disabled, "ignore": ignore, "options": options,
    }))


if __name__ == "__main__":
    main()
