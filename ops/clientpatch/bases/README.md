# Registered client bases

Each pristine client install gets one `<id>.toml`. It holds the build, a
description and the sha256 of every DBC. **It holds hashes only**; the DBC
files never enter Git.

A build runs only on a base whose DBCs match a registered fingerprint. A new
Turtle build, a localised client or a modified DBC therefore stops the build
with a clear message, instead of producing a patch from the wrong data.

Register the owner's clean client once (see [the README](../README.md),
"Register the client base"):

    python -m clientpatch fingerprint --base <extracted DBFilesClient dir> \
        --id turtle-1.18.1-enUS --client "Turtle WoW 1.18.1 (build 7272), English" \
        --registered "<date>, <who>" --write

No base is registered here yet, because the cloud session has no client.
