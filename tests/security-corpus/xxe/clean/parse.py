# CLEAN: defusedxml refuses DTDs/external entities.
from defusedxml.ElementTree import fromstring
def parse(xml_bytes):
    return fromstring(xml_bytes)  # forbid_dtd / forbid_entities by default
