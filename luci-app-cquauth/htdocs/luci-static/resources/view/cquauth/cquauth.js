'use strict';
'require form';
'require uci';
'require view';
'require rpc';
'require fs';
'require ui';
'require tools.widgets as widgets';
'require poll';

var callGetStatus = rpc.declare({
    object: 'cquauth',
    method: 'get_status',
    params: ['interface'],
});

var callRunning = rpc.declare({
    object: 'cquauth',
    method: 'running',
});

var callLogin = rpc.declare({
    object: 'cquauth',
    method: 'login',
    params: ['user', 'pass', 'interface', 'ua', 'terminal_type'],
});

var callLogout = rpc.declare({
    object: 'cquauth',
    method: 'logout',
    params: ['interface'],
});

var callDiagnose = rpc.declare({
    object: 'cquauth',
    method: 'diagnose',
    params: ['interface'],
});

var callGetLogs = rpc.declare({
    object: 'cquauth',
    method: 'get_logs',
    params: ['lines'],
});

var pollAdded = false;

// 秒 -> "Xd Xh Xm Xs"; 门户的 time 字段实测每秒 +1, 即在线时长(秒)
function fmtDuration(sec) {
    sec = parseInt(sec);
    if (isNaN(sec) || sec < 0) return 'N/A';
    var d = Math.floor(sec / 86400); sec %= 86400;
    var h = Math.floor(sec / 3600); sec %= 3600;
    var m = Math.floor(sec / 60); var s = sec % 60;
    var out = '';
    if (d) out += d + '天';
    if (h || d) out += h + '时';
    out += m + '分' + s + '秒';
    return out;
}

// 门户 flow 字段(实测非实时, 刷新很慢, 属计费口径), 字节 -> 人类可读
function fmtBytes(n) {
    n = parseInt(n);
    if (isNaN(n) || n < 0) return 'N/A';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(2)) + ' ' + u[i];
}

function accountsFromUci() {
    var list = [];
    uci.sections('cquauth', 'account', function(s) {
        if (s.interface) {
            list.push({
                sid: s['.name'],
                user: s.user,
                pass: s.pass,
                ua: s.ua,
                terminal_type: s.terminal_type || 'pc',
                enabled: s.enabled,
                interface: s.interface
            });
        }
    });
    return list;
}

function notify(ok, title, msg) {
    ui.addNotification(title, E('p', {}, msg), ok ? 'info' : 'warning');
}

function doAction(btn, label, fn, onDone) {
    var old = btn.textContent;
    btn.disabled = true;
    btn.textContent = label;
    fn().then(function(r) {
        onDone(r);
    }).catch(function(e) {
        notify(false, _('操作失败'), (e && e.message) ? e.message : String(e));
    }).finally(function() {
        btn.disabled = false;
        btn.textContent = old;
    });
}

function createStatusTable() {
    return E('table', { 'class': 'table', 'id': 'cquauth-status-table' }, [
        E('tr', { 'class': 'tr table-titles' }, [
            E('th', { 'class': 'th' }, _('接口')),
            E('th', { 'class': 'th' }, _('账号')),
            E('th', { 'class': 'th' }, _('门户')),
            E('th', { 'class': 'th' }, _('IP地址')),
            E('th', { 'class': 'th' }, _('在线时长')),
            E('th', { 'class': 'th', 'title': _('来自门户的计费流量, 非实时, 刷新很慢') }, _('流量(计费)')),
            E('th', { 'class': 'th' }, _('操作'))
        ])
    ]);
}

function buildActionCell(acc) {
    var btnAuth = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, _('立即认证'));
    var btnLogout = E('button', { 'class': 'btn cbi-button cbi-button-reset' }, _('注销'));
    var btnDiag = E('button', { 'class': 'btn cbi-button' }, _('诊断'));

    btnAuth.addEventListener('click', function() {
        doAction(btnAuth, _('认证中…'), function() {
            return callLogin(acc.user, acc.pass, acc.interface, acc.ua, acc.terminal_type);
        }, function(r) {
            notify(r && r.success, r && r.success ? _('认证成功') : _('认证失败'),
                (r && r.message) ? r.message : _('无返回'));
        });
    });

    btnLogout.addEventListener('click', function() {
        if (!confirm(_('确定注销当前认证吗? 若服务处于启用状态, 守护进程会在下个检查周期自动重新认证。')))
            return;
        doAction(btnLogout, _('注销中…'), function() {
            return callLogout(acc.interface);
        }, function(r) {
            notify(r && r.success, r && r.success ? _('注销成功') : _('注销失败'),
                (r && r.message) ? r.message : _('无返回'));
        });
    });

    btnDiag.addEventListener('click', function() {
        doAction(btnDiag, _('诊断中…'), function() {
            return callDiagnose(acc.interface);
        }, function(r) {
            if (r && r.success)
                notify(true, _('诊断快照已生成'), _('路径: ') + (r.path || '') + _('  (可在"最近日志"或 SSH 查看内容)'));
            else
                notify(false, _('诊断失败'), (r && r.message) ? r.message : _('无返回'));
        });
    });

    return E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [ btnAuth, ' ', btnLogout, ' ', btnDiag ]);
}

function updateStatus(table, accounts) {
    var rows = table.querySelectorAll('tr:not(.table-titles)');
    var rowMap = new Map();
    rows.forEach(function(row) { rowMap.set(row.getAttribute('data-iface'), row); });

    accounts.forEach(function(acc) {
        var row = rowMap.get(acc.interface);
        if (!row) {
            row = E('tr', { 'class': 'tr', 'data-iface': acc.interface }, [
                E('td', { 'class': 'td' }, acc.interface || 'N/A'),
                E('td', { 'class': 'td' }, '…'),
                E('td', { 'class': 'td' }, '…'),
                E('td', { 'class': 'td' }, '…'),
                E('td', { 'class': 'td' }, '…'),
                E('td', { 'class': 'td' }, '…'),
                buildActionCell(acc)
            ]);
            table.appendChild(row);
        }
        callGetStatus(acc.interface).then(function(result) {
            var authed = result && result.uid && result.uid !== 'N/A';
            row.cells[1].textContent = (result && result.uid) ? result.uid : 'N/A';
            if (result && result.reachable === false) {
                row.cells[2].innerHTML = '';
                row.cells[2].appendChild(E('span', { 'style': 'color:#c44' }, _('不可达')));
            } else {
                row.cells[2].innerHTML = '';
                row.cells[2].appendChild(E('span', { 'style': authed ? 'color:#2a2' : 'color:#c80' },
                    authed ? _('已认证') : _('未认证')));
            }
            row.cells[3].textContent = (result && result.v4ip) ? result.v4ip : 'N/A';
            row.cells[4].textContent = (result && result.time && result.time !== 'N/A') ? fmtDuration(result.time) : 'N/A';
            row.cells[5].textContent = (result && result.flow && result.flow !== 'N/A') ? fmtBytes(result.flow) : 'N/A';
        }).catch(function() {
            row.cells[1].textContent = _('错误');
            row.cells[2].textContent = 'N/A';
            row.cells[3].textContent = 'N/A';
            row.cells[4].textContent = 'N/A';
            row.cells[5].textContent = 'N/A';
        });
    });

    var ts = document.getElementById('cquauth-timestamp');
    if (ts) ts.textContent = _('最后更新: ') + new Date().toLocaleString();
}

function updateDaemon(banner) {
    callRunning().then(function(r) {
        banner.innerHTML = '';
        if (r && r.running) {
            banner.appendChild(E('span', { 'style': 'color:#2a2;font-weight:bold' },
                '● ' + _('守护进程运行中') + (r.pid ? (' (PID ' + r.pid + ')') : '')));
        } else {
            banner.appendChild(E('span', { 'style': 'color:#c44;font-weight:bold' },
                '● ' + _('守护进程未运行')));
            banner.appendChild(E('span', {}, '  ' + _('(服务已启用却不在运行, 说明守护进程崩溃或未自启)')));
        }
    }).catch(function() {
        banner.innerHTML = '';
        banner.appendChild(E('span', {}, _('无法获取守护进程状态')));
    });
}

return view.extend({

    load: function() {
        return Promise.all([
            uci.load('cquauth'),
            L.resolveDefault(fs.list('/sys/class/net'), [])
        ]);
    },

    render: function(data) {
        var m, s, o;

        m = new form.Map('cquauth', _('CQU Auth Client'), _('非官方重庆大学网络认证客户端'));

        // ================= 守护进程 + 状态显示 =================
        s = m.section(form.NamedSection, '_status', 'status');
        s.title = _('状态');
        s.anonymous = true;
        s.render = function() {
            var container = E('div', { 'class': 'cbi-section', 'id': 'cquauth-status-section' });

            var banner = E('div', { 'id': 'cquauth-daemon', 'style': 'margin-bottom:8px' }, '…');
            container.appendChild(banner);

            var accounts = accountsFromUci();
            if (accounts.length === 0) {
                container.appendChild(E('div', { 'class': 'alert-message warning' }, _('没有配置任何账号')));
            } else {
                var table = createStatusTable();
                container.appendChild(table);
                container.appendChild(E('div', { 'id': 'cquauth-timestamp', 'style': 'margin-top:6px;color:#888' }, ''));

                updateDaemon(banner);
                updateStatus(table, accounts);

                if (!pollAdded) {
                    poll.add(function() {
                        var t = document.querySelector('#cquauth-status-table');
                        var b = document.getElementById('cquauth-daemon');
                        if (t) updateStatus(t, accountsFromUci());
                        if (b) updateDaemon(b);
                    }, 5);
                    pollAdded = true;
                }
            }
            return container;
        };

        // ================= 最近日志 =================
        s = m.section(form.NamedSection, '_logs', 'logs');
        s.anonymous = true;
        s.render = function() {
            var box = E('textarea', {
                'id': 'cquauth-logbox', 'readonly': true, 'wrap': 'off', 'rows': 16,
                'style': 'width:100%;font-family:monospace;font-size:12px'
            }, '');

            function refresh(btn) {
                if (btn) { btn.disabled = true; }
                callGetLogs(80).then(function(r) {
                    box.value = (r && r.log) ? r.log : _('(无日志)');
                    box.scrollTop = box.scrollHeight;
                }).catch(function(e) {
                    box.value = _('读取日志失败: ') + ((e && e.message) ? e.message : String(e));
                }).finally(function() { if (btn) btn.disabled = false; });
            }

            var btnRefresh = E('button', { 'class': 'btn cbi-button' }, _('刷新日志'));
            btnRefresh.addEventListener('click', function() { refresh(btnRefresh); });

            refresh(null);

            return E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('最近日志')),
                E('div', { 'style': 'margin-bottom:6px' }, [ btnRefresh ]),
                box
            ]);
        };

        // ================= 基本设置 =================
        s = m.section(form.TypedSection, 'basic', _('基本设置'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.Flag, 'enabled', _('启用服务'));
        o.default = '1';
        o.rmempty = false;
        o.description = _('保存后自动生效, 无需手动重启服务。');

        o = s.option(form.Value, 'check_interval', _('检查间隔(秒)'));
        o.datatype = 'uinteger';
        o.default = '60';
        o.rmempty = false;
        o.description = _('每隔多少秒检查一次认证状态, 掉线则自动重认。');

        o = s.option(form.Value, 'max_attempts', _('最大尝试次数'));
        o.datatype = 'uinteger';
        o.default = '0';
        o.rmempty = false;
        o.description = _('连续认证失败达到此次数后禁用该账号; 0 表示无限重试。');

        o = s.option(form.Flag, 'enable_ecmp', _('启用 ECMP'));
        o.default = '0';
        o.rmempty = false;
        o.description = _('多 WAN 负载均衡。单 WAN 路由器保持关闭。');

        o = s.option(form.Value, 'ping_target', _('Ping目标'));
        o.default = '223.5.5.5';
        o.rmempty = false;
        o.depends('enable_ecmp', '1');
        o.description = _('仅用于 ECMP 故障转移时探测链路, 不参与认证判定。');

        o = s.option(form.Value, 'ecmp_table', _('ECMP路由表'));
        o.default = 'main';
        o.rmempty = false;
        o.depends('enable_ecmp', '1');
        o.description = _('默认 main, 可自定义搭配 ip rule 使用。');

        // ================= 账号配置 =================
        s = m.section(form.TableSection, 'account', _('账号配置'));
        s.title = _('账号配置');
        s.anonymous = true;
        s.addremove = true;

        o = s.option(form.Flag, 'enabled', _('启用'));
        o.default = '0';
        o.rmempty = false;

        o = s.option(form.Value, 'user', _('用户名'));
        o.rmempty = false;

        o = s.option(form.Value, 'pass', _('密码'));
        o.password = true;
        o.rmempty = false;

        o = s.option(widgets.DeviceSelect, 'interface', _('网络接口'));
        o.noaliases = true;
        o.nobridges = true;
        o.rmempty = false;

        o = s.option(form.Value, 'ua', _('User Agent'));
        o.default = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0';
        o.rmempty = false;

        o = s.option(form.ListValue, 'terminal_type', _('终端类型'));
        o.value('phone', _('手机'));
        o.value('pc', _('电脑'));
        o.default = 'pc';
        o.rmempty = false;

        return m.render();
    }
});
