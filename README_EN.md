# luci-app-xc

A LuCI Xray node management plugin for OpenWrt / ImmortalWrt 21.02-24.10.

## Features

- **Node Management**: Create, edit, delete self-hosted nodes; supports VLESS, VMess, Trojan, Shadowsocks, SOCKS, raw outbound
- **Manual Switching**: Select one node; all traffic uses that node
- **Quick Probes**: Single or bulk node test with configurable concurrency (1-5, default 3), SSR Plus-style
- **Local Import**: Paste share links or upload files; preview before commit
- **Healthy Switching**: Automatic Xray config validation, port health checks, and rollback on failure
- **Manual Rollback**: One-click restore of the last working configuration
- **Status Monitoring**: 5-second polling with endpoints and exit IP
- **Log Viewer**: Tail and clear operational logs; secrets automatically redacted

## Not Included

- Subscription management
- Transparent proxy (TPROXY / TUN)
- sing-box kernel support
- Dedicated node routing
- Multi-user / multi-config

## Dependencies

- `luci-compat` `lua` `libuci-lua` `luci-lib-jsonc`
- `curl` `ca-bundle`
- `xray-core` (>= 1.8.0 recommended)

## Installation

### Via feeds

```
cd /path/to/openwrt
echo "src-git xc https://github.com/deanzai/luci-app-xc.git" >> feeds.conf.default
./scripts/feeds update xc
./scripts/feeds install luci-app-xc
make package/luci-app-xc/compile V=s
```

### SDK build

```
git clone https://github.com/deanzai/luci-app-xc.git package/luci-app-xc
./scripts/feeds update base
./scripts/feeds install luci-compat luci-lib-jsonc
make package/luci-app-xc/compile V=s
```

Artifact: `bin/packages/*/luci/luci-app-xc_0.1.0-1_all.ipk`

### Direct install

```
opkg install /tmp/luci-app-xc_0.1.0-1_all.ipk
```

Legacy xc config is automatically backed up to `/etc/xc/legacy-backup-<timestamp>/`.

## Usage

1. After install, open LuCI -> Services -> Xray node switching
2. **Settings**: Enable the plugin, configure listen address and ports
3. **Nodes**: Add self-hosted nodes
4. **Status**: View runtime status, test nodes, switch or rollback
5. **Import**: Paste share links or upload files; preview then commit

### SOCKS / HTTP Proxy

When enabled, listens on:
- SOCKS5: `192.168.6.1:7890`
- HTTP CONNECT: `192.168.6.1:10809`

## Migration

When upgrading from a legacy xc script, the first install will:
1. Back up old config to `/etc/xc/legacy-backup-<timestamp>/`
2. Convert nodes to the new UCI format
3. Disable the old service only after the new config passes Xray validation

## Rollback

If the new config has issues:

```
/usr/bin/xc rollback
```

Or manually from backup:

```
cp /etc/xc/legacy-backup-*/nodes.json /etc/xc/nodes.json
```

## Development

```
git clone https://github.com/deanzai/luci-app-xc.git
cd luci-app-xc
sh scripts/bootstrap-lua.sh
.tools/lua5.1 tests/run.lua
```

## License

GPL-3.0-only
