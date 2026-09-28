# Nostalgia Launcher templates

These files contain placeholders only. The real files, with the patch host
name and the realm IP, live on the patch host and never in Git: the
repositories are public (design section 6).

| File | Becomes | Filled by |
|---|---|---|
| `nostalgia_launcher.json` | the setup file each friend imports once | the owner fills in `<patch-host>` and `<radmin-ip-of-realmd>` |
| `catalog/assets.json` | `https://<patch-host>/catalog/assets.json` | `python -m clientpatch catalog --build-info <out>/build-info.json --url-base https://<patch-host>/files` prints the entry |
| `catalog/addons.json` | `https://<patch-host>/catalog/addons.json` | each addon release: the commit SHA behind each per-addon tag (design 5.2) |
| `catalog/mods.json` | `https://<patch-host>/catalog/mods.json` | stays empty until stage 4, then gets pinned `direct_file` entries with sha1 |

Format reference: the Nostalgia Launcher `examples/README.md`
(`Ourouk/nostalgia-launcher` at `a3b04f2`, read for design section 4.2).
Every URL must be `https://`, with a certificate the friend's PC trusts.
