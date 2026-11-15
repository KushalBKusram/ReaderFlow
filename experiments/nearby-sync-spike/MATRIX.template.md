# Nearby Sync validation matrix

Copy this file to a dated file under `.readerflow-nearby-sync/` before each run;
that local results directory is ignored. Do not record pairing secrets, Raindrop
tokens, article text, or generated media.

| Sender | Receiver | Network | Fresh pair | Resume after Wi-Fi loss | Resume after restart | Final digest | Revoke/re-pair | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| macOS | macOS | Home Wi-Fi |  |  |  |  |  |  |  |
| macOS | iPhone | Home Wi-Fi |  |  |  |  |  |  |  |
| macOS | Android | Home Wi-Fi |  |  |  |  |  |  |  |
| Windows | iPhone | Home Wi-Fi |  |  |  |  |  |  |  |
| Windows | Android | Home Wi-Fi |  |  |  |  |  |  |  |

For each row, capture the app build/commit, OS version, device model, transfer
size, pairing-expiry and consent behaviour, recovery time, encrypted-channel
evidence, and a concise reproducible failure note.

Gate passing requires every supported desktop/mobile combination to pass the
fresh-pair, interruption, restart, integrity, and revoke/re-pair checks on an
ordinary local network. A desktop-to-desktop pass is useful rehearsal evidence,
not a substitute for this matrix.
