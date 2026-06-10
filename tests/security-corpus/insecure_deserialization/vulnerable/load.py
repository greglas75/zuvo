import pickle
def load(blob):  # VULNERABLE: pickle.loads on attacker-controlled bytes → RCE
    return pickle.loads(blob)
