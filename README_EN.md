# luci-app-xc

A LuCI Xray self-hosted node management and switching plugin for OpenWrt / ImmortalWrt 21.02-24.10.

The plugin uses Xray-core as its runtime kernel and manages one self-hosted node set. The selected node is used as the unified outbound with built-in GeoIP/GeoSite preset routing. Subscription management, transparent proxying, and user-defined dedicated-node routing remain out of scope.

## Features

- **Node management**: Create, edit, delete, and enable/disable nodes
- **Protocols**: Structured VLESS, VMess, Trojan, Shadowsocks, and SOCKS support; use a complete raw outbound JSON object for uncommon combinations
- **Quick switching**: Switch from the node row; the successful active node is highlighted without waiting for a CBI save-and-refresh cycle
- **Node probes**: Test one node or all nodes; concurrency is configurable from 1 to 5 and defaults to 3. This is a connectivity/latency test, not a bandwidth test
- **Local import**: Paste share links or upload text/JSON files, preview them, then confirm the import; subscription fetching is not included
- **Healthy switching**: Validate the Xray configuration, check SOCKS/HTTP listeners and the health URL after startup, and restore the last known-good configuration on failure
- **Manual rollback**: Restore the previous runtime configuration from the status area or `/usr/bin/xc rollback`
- **Core management**: Upload one Xray-core ELF in LuCI and verify SHA-256, device architecture, version output, and the current configuration before activation
- **Core rollback**: Automatically restore the previous core after a failed activation; managed versions never overwrite `/usr/bin/xray`
- **Status monitoring**: The Settings page shows service state, active node, listeners, and the exit IP observed through the selected node
- **Log viewer**: One log page merges XC and Xray runtime logs with All/Error/Warning/Info/Debug filtering
- **Preset routing**: Applies the recovered GeoIP/GeoSite domestic-direct, foreign-proxy, ad-blocking, and custom domain rules through the selected outbound
- **Privacy controls**: Access logging is disabled; node passwords, UUIDs, links, raw JSON secrets, and log credentials are redacted

## Settings

| Setting | Description | Default |
| --- | --- | --- |
| Enable | Enable or disable the XC service | Disabled |
| Xray log level | Controls which Xray runtime messages are generated | `warning` |
| Geo routing | Enable the built-in GeoIP/GeoSite preset routing; disabling it keeps only private-network direct routing | `1` |
| Active node | Select the unified outbound; only enabled nodes are listed | Not selected |
| Listen mode | LAN address mode | `lan` |
| Listen address | Derived read-only from `network.lan`, with `127.0.0.1` as fallback | Automatic |
| SOCKS port | Local SOCKS5 listener port | `7890` |
| HTTP port | Local HTTP CONNECT listener port | `10809` |
| Probe concurrency | Number of simultaneous requests for “Test all” | `3` |
| Probe timeout | Per-node connectivity timeout, 1-10 seconds | `3` seconds |
| Probe URL | HTTP/HTTPS endpoint used by node probes | `https://www.gstatic.com/generate_204` |
| Health check URL | Endpoint used after switching and for exit-IP observation | `https://api.ipify.org` |
| Health check timeout | Post-switch health-check timeout, 1-30 seconds | `15` seconds |

The Xray level controls log generation: `error` produces errors only, `warning` produces warnings and errors, `info` includes informational messages, and `debug` enables the most verbose runtime output. The log-page filter only filters logs that already exist; selecting Debug there cannot make an Xray configured at Error emit debug entries.

The single Log page combines:

- XC lifecycle, switching, probing, import, rollback, rendering, and error records
- Xray runtime records read from the system log; access logging remains disabled

Clear only truncates the XC log. It cannot erase the shared OpenWrt system log or historical Xray entries.

## Not included

- Subscription management
- Transparent proxy (TPROXY / TUN)
- sing-box kernel support
- User-defined dedicated-node routing pages
- Multi-user / multi-config
- Remote Xray-core downloads, subscription-style upgrades, and automatic remote upgrades

## Dependencies and compatibility

- `luci-compat`, `lua`, `libuci-lua`, `luci-lib-jsonc`
- `curl`, `ca-bundle`
- `v2ray-geoip`, `v2ray-geosite`, which provide the GeoIP/GeoSite data files
- `xray-core`, supplied by the target OpenWrt/ImmortalWrt feeds; the plugin does not bundle the core

The same plugin source can be built on 21.02, 23.05, or 24.10, but each target requires its own SDK/Buildroot and feeds:

```text
21.02 SDK/Buildroot -> 21.02 luci-app-xc IPK + 21.02 xray-core
23.05 SDK/Buildroot -> 23.05 luci-app-xc IPK + 23.05 xray-core
24.10 SDK/Buildroot -> 24.10 luci-app-xc IPK + 24.10 xray-core
```

Do not publish an IPK built in one distribution environment as the native package for another. Even though the LuCI package is `all` architecture, its dependencies and runtime compatibility still come from the target distribution.

The minimum compatibility baseline is Lua 5.1 and LuCI 21.02; 23.05 and 24.10 use their respective LuCI/Xray feeds. The plugin does not use sing-box and does not require upgrading the Go toolchain on 21.02.

## Geo routing assets

When `Geo routing` is enabled, both files must exist on the device:

```text
/usr/share/xray/geosite.dat
/usr/share/xray/geoip.dat
```

XC prefers `/usr/share/xray`. On OpenWrt/ImmortalWrt 21.02, when that directory does not
contain both files, it falls back to the paths installed by `v2ray-geoip` and
`v2ray-geosite`:

```text
/usr/share/v2ray/geosite.dat
/usr/share/v2ray/geoip.dat
```

23.05/24.10 normally use `/usr/share/xray`. The selector requires both files in one directory
and never mixes the two locations. Generated Xray configurations use
`domainStrategy=IPIfNonMatch`, so a domain rule that does not match can still perform GeoIP
resolution.

XC checks them before rendering, switching, and startup. If either file is missing it returns
`routing_assets_missing` and does not start an invalid configuration. The data files are not
embedded in the LuCI IPK; copy them from the target distribution's Xray asset package or a
verified device. For troubleshooting, disable `Geo routing` to keep only private-network direct routing.

## Installation

### Via feeds

```sh
cd /path/to/openwrt
echo "src-git xc https://github.com/deanzai/luci-app-xc.git" >> feeds.conf.default
./scripts/feeds update xc
./scripts/feeds install luci-app-xc
make package/luci-app-xc/compile V=s
```

### SDK or source-tree build

```sh
git clone https://github.com/deanzai/luci-app-xc.git package/luci-app-xc
./scripts/feeds update base
./scripts/feeds install luci-compat luci-lib-jsonc xray-core v2ray-geoip v2ray-geosite
make package/luci-app-xc/compile V=s
```

The current source package version is `0.1.0-r13`; a typical artifact is:

```text
bin/packages/**/luci-app-xc_0.1.0-r13_all.ipk
```

GitHub Actions builds OpenWrt 21.02, 23.05, and 24.10. The older 21.02 and 23.05
`luci.mk` may ignore `PKG_RELEASE`, so an SDK output can omit the release suffix. Before
uploading, CI adds an explicit platform suffix to every IPK so Release assets cannot be
mistaken for one another. It also normalizes the control metadata version to `0.1.0-r13`
so opkg can upgrade installations reporting the older `0.1.0-10` version:

```text
21.02: luci-app-xc_0.1.0-r13_all_openwrt-21.02.ipk
23.05: luci-app-xc_0.1.0-r13_all_openwrt-23.05.ipk
24.10: luci-app-xc_0.1.0-r13_all_openwrt-24.10.ipk
```

Translation packages use the LuCI PO version independently and receive the same suffix:

```text
luci-i18n-xc-zh-cn_0.1.0-r13_all_openwrt-21.02.ipk
luci-i18n-xc-zh-cn_0.1.0-r13_all_openwrt-23.05.ipk
luci-i18n-xc-zh-cn_0.1.0-r13_all_openwrt-24.10.ipk
```

Each platform artifact also contains `SHA256SUMS-openwrt-<version>.txt`. Install only the main
and translation IPKs matching the device distribution; do not infer cross-release compatibility
from the `all` package architecture.

### Direct installation

Back up `/etc/config/xc` and any legacy XC runtime files before installing the IPK built for the target system:

```sh
opkg install /tmp/luci-app-xc_0.1.0-r13_all.ipk /tmp/luci-i18n-xc-zh-cn_0.1.0-r13_all.ipk
```

When using GitHub Release assets, replace both paths with files carrying the same platform suffix.
The translation package is not a runtime dependency of the main package, so it must be installed
explicitly for a complete Simplified Chinese interface.

Do not use `opkg --force-depends`. If the device already has an Xray binary installed outside opkg, verify that binary first and use a device-specific package only when its dependency handling is understood; the normal release package retains the `xray-core` dependency.

## Usage

After installation, open LuCI: `Services -> Xray node switching`.

1. **Settings**: Enable XC and review listener, probe, and health-check settings.
2. **Nodes**: Add or edit self-hosted nodes. Each row provides probe, switch, edit, and delete actions.
3. **Switch**: Click “Switch” on the target row. Validation, startup, health checks, and rollback run independently; “Save & Apply” is not required first.
4. **Save configuration**: New/edit/enable/disable changes and port or URL changes still use LuCI “Save & Apply”. This configuration flow is separate from quick switching.
5. **Probe**: Use “Test” for one node or “Test all” for a batch run. Results are shown in the Latency column.
6. **Logs**: Filter All, Error, Warning, Info, or Debug and click Refresh. The filter does not change Xray’s configured runtime level.

### Manual Xray-core replacement

Open `Services → Xray node switching → Xray core` and select one Xray ELF executable matching the device architecture. The device computes SHA-256 and checks the ELF header, `xray version` output, and the current configuration with `run -test`; only a validated file is installed.

Activating a core uses the same runtime lock as node switching, saves the current core marker, restarts XC, and checks the service, listeners, and health endpoint. A failed activation restores the previous core automatically; if a manual core has no usable previous marker, page rollback safely returns to the system core. The system package core remains `/usr/bin/xray`; managed versions live under `/etc/xc/xray/versions/` and never overwrite an `opkg`-owned file.

### SOCKS / HTTP proxy

After XC is enabled and a node is successfully selected, listeners use the current LAN address:

- SOCKS5: `<LAN address>:7890`
- HTTP CONNECT: `<LAN address>:10809`

The address is derived from `network.lan`, not hard-coded to `192.168.6.1`. Use the status area for the actual endpoint.

### Exit IP

`Exit IP` is the public IP observed by requesting the health-check URL through XC’s local SOCKS listener and the selected node. It is not the router’s WAN address. A protected runtime cache avoids repeated requests for a short period; the UI shows `Unavailable` when service or listener health is insufficient.

## Migration and recovery

When upgrading from the legacy xc switching script, the first installation creates a restricted backup under `/etc/xc/legacy-backup-<timestamp>/` and takes over only after validation:

1. Back up legacy nodes, current/runtime configuration, and legacy service files when present.
2. Convert legacy nodes to the new UCI format.
3. Validate the candidate with Xray `run -test`.
4. Stop and disable the old `xc-xray` service only after takeover succeeds.

If migration fails, the legacy service and backup remain available. For runtime recovery:

```sh
/usr/bin/xc status
/usr/bin/xc test
/usr/bin/xc rollback
```

Manual restoration from a backup is also possible, but verify the backup directory and target files before replacing a working configuration.

## Development and verification

```sh
git clone https://github.com/deanzai/luci-app-xc.git
cd luci-app-xc
sh scripts/bootstrap-lua.sh
sh tests/run-host.sh
```

Before a release, build separately in the target 21.02, 23.05, and 24.10 environments and verify the LuCI menu, configuration save, node switching, probing, logging, and rollback on real devices.

## License

GPL-3.0-only
