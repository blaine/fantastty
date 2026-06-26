# Remote Engine

Fantastty's remote engine connects to an SSH-hosted tmux workspace by deploying a bundled remote helper, bootstrapping it over SSH, then attaching the macOS app to the helper over QUIC. The helper owns tmux control-mode interaction and sends structured workspace, pane, keyframe, and delta messages to the app. The macOS app renders those messages through the remote grid runtime and falls back to SSH control mode when remote-engine startup fails before panes are created.

## Mainline Components

- `Fantastty/Models/RemoteEngineClient.swift`: SSH bootstrap, helper deployment, QUIC attach material parsing, transport setup, diagnostics, and fallback classification.
- `Fantastty/Models/RemoteGridProtocol.swift`: Codable message contract shared by the helper and app.
- `Fantastty/Models/RemotePaneGridState.swift`: app-side structured grid state, keyframe validation, datagram viability, cursor, active screen, and scroll-region state.
- `Fantastty/Models/RemoteWorkspaceRuntime.swift`: workspace/window/pane routing for remote structured-grid messages.
- `Fantastty/Models/RemoteWorkspaceBridge.swift`: bridge between remote runtime state and app surfaces, including reconnect rendering and predictive echo scheduling.
- `Fantastty/Models/RemotePredictiveEchoEngine.swift`: conservative local prediction for direct printable input after authoritative echo confidence is established.
- `tools/remote-engine-helper/helper`: the remote helper source used for bundled app artifacts.
- `tools/remote-engine-helper/package_app_artifacts.sh`: builds bundled `linux-amd64`, `linux-arm64`, and `darwin-arm64` helper artifacts and `libghostty-vt`.
- `tools/remote-engine-helper/verify_app_artifacts.py`: verifies a built app contains a valid remote-engine helper manifest and matching checksums.

## Release Artifact Flow

Release builds set `FANTASTTY_PACKAGE_REMOTE_ENGINE_ARTIFACTS=1`. The Xcode build phase invokes `make remote-engine-app-artifacts`, which builds helper artifacts into `Fantastty/Resources/RemoteEngine`. The generated manifest and remote helper payloads are intentionally ignored in git. Release packaging then runs `make remote-engine-verify-app-artifacts APP=/path/to/Fantastty.app` before signing and packaging.

## Security Boundaries

- SSH is the trust bootstrap for helper deployment and returned QUIC attach material.
- The app pins the helper's QUIC certificate hash from SSH-delivered attach material.
- One-time attach keys are short-lived and are not persisted by the app's support bundle.
- Helper evidence gate logging redacts attach keys before writing durable logs or run-root capture files.
- Diagnostics omit one-time keys, certificate pins, bearer secrets, raw typed input, pane contents, shell commands, environment secrets, and user-local paths.

## Live and Development Gates

Live bootstrap, QUIC migration, GhosttyKit compatibility, and helper-renderer gates were used during development, but their operator harnesses are intentionally not shipped in this branch. They depend on private hosts, network switches, transient run roots, and live evidence logs that should not become mainline maintenance surface.

Do not commit raw live-gate logs. They may include hostnames, local paths, remote addresses, pane contents, or transient attach material.

## Known Release Limitations

- Same-connection QUIC network migration is not treated as the product contract. The accepted product behavior is app-layer pinned reconnect with visible reconnect/resume state.
- Predictive echo is intentionally conservative. It suppresses prediction for alternate-screen/full-screen state, paste, IME/non-printable input, focus loss, reattach, mismatch rollback, unsupported epochs, and unproven echo confidence.
- Broad release still needs deliberate soak and host-compatibility evidence before treating the remote engine as generally hardened across Linux and macOS hosts.
