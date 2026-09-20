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

// 文案与 GNOME 自身保持一致（用词取自 gnome-shell / gnome-control-center 的 zh_CN 翻译）：
//   Mobile Network→移动网络、Connected→已连接、Disconnected→已断开、
//   Connect→连接、Disconnect→断开连接、Turn Off→关闭、Settings→设置、APN→APN
const ZH = (GLib.get_language_names()[0] || 'en').toLowerCase().startsWith('zh');
const T = ZH ? {
    title: '移动网络',
    connecting: '正在连接…',
    disconnecting: '正在断开…',
    off: '已关闭',
    absent: '模组未就绪',
    unavailable: '不可用',
    disconnected: '已断开',
    reconnect: '重新连接',
    apnPrefix: 'APN',
    signal: '信号',
    operator: '运营商',
    network: '网络',
    settings: '设置',
} : {
    title: 'Mobile Network',
    connecting: 'Connecting…',
    disconnecting: 'Disconnecting…',
    off: 'Turned off',
    absent: 'Modem not ready',
    unavailable: 'Unavailable',
    disconnected: 'Disconnected',
    reconnect: 'Reconnect',
    apnPrefix: 'APN',
    signal: 'Signal',
    operator: 'Operator',
    network: 'Network',
    settings: 'Settings',
};

// EARFCN → LTE 频段（只列常用频段；查不到就显示原始 EARFCN）
const LTE_BANDS = [
    [1, 0, 599], [2, 600, 1199], [3, 1200, 1949], [4, 1950, 2399],
    [5, 2400, 2649], [7, 2750, 3449], [8, 3450, 3799], [20, 6150, 6449],
    [28, 9210, 9659], [38, 37750, 38249], [39, 38250, 38649],
    [40, 38650, 39649], [41, 39650, 41589],
];

function bandFromEarfcn(earfcn) {
    if (typeof earfcn !== 'number')
        return null;
    for (const [band, lo, hi] of LTE_BANDS) {
        if (earfcn >= lo && earfcn <= hi)
            return band;
    }
    return null;
}

// RAT → 用户熟悉的制式说法（GNOME 网络面板用 4G/3G/2G 这种叫法）
function ratLabel(rat) {
    if (!rat)
        return '—';
    const r = String(rat).toUpperCase();
    if (r.includes('LTE'))
        return ZH ? '4G（LTE）' : '4G (LTE)';
    if (r.includes('UMTS') || r.includes('HSDPA') || r.includes('HSPA'))
        return ZH ? '3G（UMTS）' : '3G (UMTS)';
    if (r.includes('GSM') || r.includes('EDGE') || r.includes('GPRS'))
        return ZH ? '2G（GSM）' : '2G (GSM)';
    if (r.includes('NR'))
        return ZH ? '5G（NR）' : '5G (NR)';
    return String(rat);
}

const LteToggle = GObject.registerClass(
class LteToggle extends QuickMenuToggle {
    _init(settings, openPrefs) {
        super._init({
            title: T.title,
            iconName: ICON_OFF,
            toggleMode: true,
            menuEnabled: true,
        });
        this._settings = settings;
        this._openPrefs = openPrefs;
        this._setSubtitle('…');

        this.connect('clicked', () => this._setState(this.checked));

        // 菜单：和 GNOME 自带磁贴一样，右侧 > 打开菜单
        this.menu.setHeader('network-cellular-symbolic', T.title);

        // 详情行（只读）：信号 / 运营商 / 网络（制式·频段·EARFCN）/ APN
        this._signalItem = new PopupMenu.PopupMenuItem(`${T.signal}：—`);
        this._operatorItem = new PopupMenu.PopupMenuItem(`${T.operator}：—`);
        this._networkItem = new PopupMenu.PopupMenuItem(`${T.network}：—`);
        this._apnItem = new PopupMenu.PopupMenuItem(`${T.apnPrefix}：…`);
        for (const item of [this._signalItem, this._operatorItem,
                            this._networkItem, this._apnItem])
            item.setSensitive(false);
        this.menu.addMenuItem(this._signalItem);
        this.menu.addMenuItem(this._operatorItem);
        this.menu.addMenuItem(this._networkItem);
        this.menu.addMenuItem(this._apnItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._refreshItem = new PopupMenu.PopupMenuItem(T.reconnect);
        this._refreshItem.connect('activate', () => {
            this._sync();
            this.menu.close();
        });
        this.menu.addMenuItem(this._refreshItem);

        this._prefsItem = new PopupMenu.PopupMenuItem(`${T.settings}…`);
        this._prefsItem.connect('activate', () => {
            try {
                this._openPrefs?.();
            } catch (e) {
                logError(e);
            }
            this.menu.close();
        });
        this.menu.addMenuItem(this._prefsItem);

        this._apnItem.label.text = `${T.apnPrefix}：${this._readApn()}`;

        // 打开菜单时重新读一次 APN（改完 /etc/fibocom-l850-lte/modem.conf 不必重登）
        this.menu.connect('open-state-changed', (menu, isOpen) => {
            if (isOpen)
                this._apnItem.label.text = `${T.apnPrefix}：${this._readApn()}`;
        });

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
        this._setSubtitle(on ? T.connecting : T.disconnecting);
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

        // 详情行
        if (typeof d.rsrp_dbm === 'number') {
            const bars = Math.max(0, Math.min(4, d.bars ?? 0));
            this._signalItem.label.text = `${T.signal}：${d.rsrp_dbm} dBm（RSRP）· ${bars}/4`;
        } else {
            this._signalItem.label.text = `${T.signal}：—`;
        }
        if (d.operator || d.mcc) {
            const plmn = (d.mcc && d.mnc !== undefined)
                ? `（${d.mcc}/${String(d.mnc).padStart(2, '0')}）` : '';
            this._operatorItem.label.text = `${T.operator}：${d.operator ?? '—'}${plmn}`;
        } else {
            this._operatorItem.label.text = `${T.operator}：—`;
        }
        if (connected) {
            const band = bandFromEarfcn(d.earfcn);
            const parts = [ratLabel(d.rat)];
            if (band)
                parts.push(`${ZH ? '频段' : 'Band'} B${band}`);
            if (typeof d.earfcn === 'number')
                parts.push(`EARFCN ${d.earfcn}`);
            this._networkItem.label.text = `${T.network}：${parts.join(' · ')}`;
        } else {
            this._networkItem.label.text = `${T.network}：—`;
        }

        if (connected) {
            const bars = Math.max(0, Math.min(4, d.bars ?? 0));
            this.set({iconName: ICON_BY_BARS[bars]});
            // 副标题学 GNOME 的 Wi-Fi 磁贴：只放"网络名"（信号强弱由图标表达），
            // RSRP/制式/频段/EARFCN 这些数值都放在菜单的详情行里。
            const opName = d.operator
                || (d.mcc ? `${d.mcc}/${String(d.mnc ?? '').padStart(2, '0')}` : null);
            this._setSubtitle(opName ?? T.disconnected);
        } else if (d.state === 'off') {
            this.set({iconName: ICON_OFF});
            this._setSubtitle(T.off);
        } else if (d.state === 'absent') {
            this.set({iconName: ICON_OFF});
            this._setSubtitle(T.absent);
        } else if (d.state === 'error') {
            this.set({iconName: ICON_OFF});
            this._setSubtitle(T.unavailable);
        } else {
            this.set({iconName: ICON_OFF});
            this._setSubtitle(T.disconnected);
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
