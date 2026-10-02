import base64
import datetime
import os

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(os.environ["SPARKLE_ED_SEED"]))
data = open("DAN.RIDE.dmg", "rb").read()
signature = base64.b64encode(key.sign(data)).decode()

repo = os.environ["GITHUB_REPOSITORY"]
tag = os.environ["TAG"]
version = os.environ["VERSION"]
build = os.environ["BUILD_NUMBER"]
published = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")

appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DAN.RIDE</title>
    <item>
      <title>{version}</title>
      <pubDate>{published}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.3</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/{repo}/releases/download/{tag}/DAN.RIDE.dmg" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
open("appcast.xml", "w").write(appcast)
