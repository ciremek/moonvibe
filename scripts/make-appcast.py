"""Write the Sparkle appcast of one Moonvibe release to stdout.

The release notes are CHANGELOG.md's sections, as markdown, from this version back to
0.5.0, the first one that updates itself: someone who skipped versions sees all they
missed, and Moonvibe (MVUpdater) cuts the versions it already has. The enclosure
attributes (sparkle:edSignature and length) come from Sparkle's sign_update run on the DMG.
Moonvibe requires a signed appcast (SURequireSignedFeed): run sign_update on the result too.

Usage: make-appcast.py VERSION DMG_URL ENCLOSURE_ATTRIBUTES MINIMUM_MACOS CHANGELOG
"""

import re
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr

version, dmg_url, enclosure, minimum_macos, changelog = sys.argv[1:6]

if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', enclosure):
    sys.exit(f"Unexpected enclosure attributes from sign_update: {enclosure}")

FIRST_SELF_UPDATING = (0, 5, 0)


def version_key(text):
    return tuple(int(part) for part in text.split("."))


# Each version's section starts with "## <version> · <name> · <date>", newest first
sections = []
for line in open(changelog, encoding="utf-8").read().splitlines():
    heading = re.match(r"## (\d+(?:\.\d+)+)(\s|$)", line)
    if heading:
        sections.append((heading.group(1), [line]))
    elif sections:
        sections[-1][1].append(line)

start = next((i for i, (section_version, _) in enumerate(sections) if section_version == version), None)
if start is None:
    sys.exit(f"{changelog} has no section for {version}")
if len(sections[start][1]) < 2 or not "\n".join(sections[start][1][1:]).strip():
    sys.exit(f"The {version} section of {changelog} is empty")

notes = "\n\n".join("\n".join(lines).strip() for section_version, lines in sections[start:]
                    if version_key(section_version) >= FIRST_SELF_UPDATING)
if "]]>" in notes:
    sys.exit(f"{changelog} can't go in CDATA")

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Moonvibe</title>
    <item>
      <title>Moonvibe {escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_macos)}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
{notes}
]]></description>
      <enclosure url={quoteattr(dmg_url)} type="application/x-apple-diskimage" {enclosure}/>
    </item>
  </channel>
</rss>""")
