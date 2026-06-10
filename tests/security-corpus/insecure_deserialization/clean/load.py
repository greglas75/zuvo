import json
def load(blob):  # CLEAN: JSON for untrusted data; pickle never on attacker input
    return json.loads(blob)
