// Fibocom L850 LTE Toggle — GNOME Shell Quick Settings extension.
//
// 本地改动（相对上游 v2，2026-09-20，作者 xmm + Codex）：
//   把纯 QuickToggle 换成 QuickMenuToggle，让磁贴和 GNOME 自带的
//   蓝牙 / 性能模式 / 网络共享 一样是 "图标 + 标题 + 副标题 + > 箭头" 的菜单磁贴；
//   菜单里提供：刷新状态 / 当前 APN / 扩展设置。
//   其余逻辑（D-Bus 调用、轮询、图标映射）与上游一致。
//
// SPDX-License-Identifier: GPL-3.0-or-later

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const BUS_NAME = 'org.fibocom.l850';
const OBJ_PATH = '/org/fibocom/l850';
const IFACE = 'org.fibocom.l850';
const DEFAULT_POLL_SECONDS = 10;
const MODEM_CONF = '/etc/fibocom-l850-lte/modem.conf';

const ICON_BY_BARS = [
    'network-cellular-signal-none-symbolic',       // 0
    'network-cellular-signal-weak-symbolic',       // 1
    'network-cellular-signal-ok-symbolic',         // 2
    'network-cellular-signal-good-symbolic',       // 3
    'network-cellular-signal-excellent-symbolic',  // 4
];
const ICON_OFF = 'network-cellular-offline-symbolic';

const LteToggle = GObject.registerClass(
class LteToggle extends QuickMenuToggle {
    _init(settings, openPrefs) {
        super._init({
            title: 'Mobile Data',
            iconName: ICON_OFF,
            toggleMode: true,
            menuEnabled: true,
        });
        this._settings = settings;
        this._openPrefs = openPrefs;
        this._setSubtitle('…');

        this.connect('clicked', () => this._setState(this.checked));

        // 菜单：和 GNOME 自带磁贴一样，右侧 > 打开菜单
        this.menu.setHeader('network-cellular-symbolic', 'Mobile Data');
        this._refreshItem = new PopupMenu.PopupMenuItem('刷新状态');
        this._refreshItem.connect('activate', () => {
            this._sync();
            this.menu.close();
        });
        this.menu.addMenuItem(this._refreshItem);

        this._apnItem = new PopupMenu.PopupMenuItem('APN: …');
        this._apnItem.setSensitive(false);
        this.menu.addMenuItem(this._apnItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._prefsItem = new PopupMenu.PopupMenuItem('扩展设置…');
        this._prefsItem.connect('activate', () => {
            try {
                this._openPrefs?.();
            } catch (e) {
                logError(e);
            }
            this.menu.close();
        });
        this.menu.addMenuItem(this._prefsItem);

        this._apnItem.label.text = `APN: ${this._readApn()}`;

        this._subtitleOk = true;
        this._busy = false;
        this._sync();

        const poll = this._settings
            ? Math.max(3, this._settings.get_int('poll-seconds'))
            : DEFAULT_POLL_SECONDS;
        this._timeout = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, poll, () => {
            this._sync();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _readApn() {
        try {
            const [ok, bytes] = GLib.file_get_contents(MODEM_CONF);
            if (ok) {
                const text = new TextDecoder().decode(bytes);
                for (const line of text.split('\n')) {
                    const m = line.match(/^\s*APN\s*=\s*(.+)\s*$/);
                    if (m)
                        return m[1].replace(/^["']|["']$/g, '');
                }
            }
        } catch (e) {
            // 读不到就显示 unknown，不影响磁贴
        }
        return 'unknown';
    }

    // The subtitle property only exists on newer shells -> never hard-depend.
    _setSubtitle(text) {
        if (!this._subtitleOk)
            return;
        try {
            this.set({subtitle: text});
        } catch (e) {
            this._subtitleOk = false;
        }
    }

    _setState(on) {
        this._setSubtitle(on ? 'connecting…' : 'disconnecting…');
        Gio.DBus.system.call(
            BUS_NAME, OBJ_PATH, IFACE, 'SetEnabled',
            new GLib.Variant('(b)', [on]), null,
            Gio.DBusCallFlags.NONE, 90000, null,
            (bus, res) => {
                try { bus.call_finish(res); } catch (e) { logError(e); }
                this._sync();
            });
    }

    _sync() {
        if (this._busy)
            return;
        this._busy = true;
        Gio.DBus.system.call(
            BUS_NAME, OBJ_PATH, IFACE, 'Status',
            null, new GLib.VariantType('(s)'),
            Gio.DBusCallFlags.NONE, 15000, null,
            (bus, res) => {
                this._busy = false;
                let data = {};
                try {
                    const reply = bus.call_finish(res);
                    const [json] = reply.deep_unpack();
                    data = JSON.parse(json);
                } catch (e) {
                    return;
                }
                this._apply(data);
            });
    }

    _apply(d) {
        const connected = d.state === 'connected';
        if (this.checked !== connected)
            this.set({checked: connected});

        if (connected) {
            const bars = Math.max(0, Math.min(4, d.bars ?? 0));
            this.set({iconName: ICON_BY_BARS[bars]});
            const parts = [];
            if (d.operator) parts.push(d.operator);
            if (d.rat) parts.push(d.rat);
            if (typeof d.rsrp_dbm === 'number') parts.push(`${d.rsrp_dbm} dBm`);
            this._setSubtitle(parts.join(' · ') || 'Connected');
        } else if (d.state === 'off') {
            this.set({iconName: ICON_OFF});
            this._setSubtitle('Off');
        } else if (d.state === 'absent') {
            this.set({iconName: ICON_OFF});
            this._setSubtitle('Modem off');
        } else if (d.state === 'error') {
            this.set({iconName: ICON_OFF});
            this._setSubtitle('Unavailable');
        } else {
            this.set({iconName: ICON_OFF});
            this._setSubtitle('Disconnected');
        }
    }

    destroy() {
        if (this._timeout) {
            GLib.source_remove(this._timeout);
            this._timeout = null;
        }
        super.destroy();
    }
});

const LteIndicator = GObject.registerClass(
class LteIndicator extends SystemIndicator {
    _init(settings, openPrefs) {
        super._init();
        this._toggle = new LteToggle(settings, openPrefs);
        this.quickSettingsItems.push(this._toggle);
    }

    destroy() {
        this._toggle.destroy();
        super.destroy();
    }
});

export default class FibocomLteExtension extends Extension {
    enable() {
        let settings = null;
        try { settings = this.getSettings(); } catch (e) { settings = null; }
        this._indicator = new LteIndicator(settings, () => this.openPreferences());
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}

