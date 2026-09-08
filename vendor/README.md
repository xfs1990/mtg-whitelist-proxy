# MTG vendor binaries

Put MTG release archives in this directory when some servers can access
`raw.githubusercontent.com` but cannot access GitHub Release assets.

Expected file names:

```text
mtg-2.2.8-linux-amd64.tar.gz
mtg-2.2.8-linux-arm64.tar.gz
mtg-2.2.8-linux-386.tar.gz
mtg-2.2.8-linux-armv7.tar.gz
mtg-2.2.8-linux-armv6.tar.gz
```

The tiny installer falls back to:

```text
https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/vendor-bin/vendor/<archive>
```
