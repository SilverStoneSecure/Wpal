#!/usr/bin/env python3
# One-time, idempotent migration of Wpal's bar.layout.right entry key in
# shell.json from an old plugin id to a new one. Needed because the host
# matches bar.layout.right entries to an installed plugin by exact string
# equality on `id` -- changing manifest.json's id alone leaves the bar icon
# with no matching entry, so this has to run against shell.json directly,
# before/alongside the manifest change taking effect, not as in-QML
# migration code (which can't run if the widget never mounts in the first
# place). See the "Rename plugin id" commit for the full story.
#
# Usage: migrate-plugin-id.py [shell.json path]
# Defaults to ~/.config/omarchy/shell.json. Always back that file up first.

import json
import os
import sys

OLD_ID = "silverstone.wpal"
NEW_ID = "io.github.silverstone.wpal"


def has_real_data(entry):
    ws = entry.get("workspaces")
    if isinstance(ws, dict) and len(ws) > 0:
        return True
    if entry.get("globalOverride"):
        return True
    return False


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.config/omarchy/shell.json")

    with open(path) as f:
        doc = json.load(f)

    right = doc.get("bar", {}).get("layout", {}).get("right", [])

    old_entry = next((e for e in right if e.get("id") == OLD_ID), None)
    new_entry = next((e for e in right if e.get("id") == NEW_ID), None)

    if new_entry is not None and has_real_data(new_entry):
        print(f"already migrated, nothing to do ({NEW_ID} has real data)")
        return

    if old_entry is None:
        print(f"nothing to migrate ({OLD_ID} not found in bar.layout.right)")
        return

    if new_entry is not None:
        # Blank placeholder under the new id -- safe to overwrite with the
        # old entry's real fields, since it carries nothing configured.
        for k, v in old_entry.items():
            if k != "id":
                new_entry[k] = v
        right.remove(old_entry)
        action = "migrated (overwrote blank placeholder under new id)"
    else:
        old_entry["id"] = NEW_ID
        action = "migrated (rewrote id in place)"

    tmp_path = path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, path)

    print(action)


if __name__ == "__main__":
    main()
