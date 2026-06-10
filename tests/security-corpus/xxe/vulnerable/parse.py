# VULNERABLE: lxml parser resolves external entities → XXE (reads local files / SSRF).
from lxml import etree
def parse(xml_bytes):
    parser = etree.XMLParser(resolve_entities=True, no_network=False)  # entities enabled
    return etree.fromstring(xml_bytes, parser)
