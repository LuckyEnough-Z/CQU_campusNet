'use strict';
'require form';
'require uci';
'require view';
'require rpc';
'require fs';
'require tools.widgets as widgets';
'require poll';

var callGetStatus = rpc.declare({
    object: 'cquauth',
    method: 'get_status',
    params: ['interface'],
});

var restartService = rpc.declare({
    object: 'cquauth',
    method: 'service',
    params: ['action']
});

var pollAdded = false;

function createStatusTable() {
    return E('table', { 'class': 'table' }, [
        E('tr', { 'class': 'tr table-titles' }, [
            E('th', { 'class': 'th' }, _('接口')),
            E('th', { 'class': 'th' }, _('账号')),
            E('th', { 'class': 'th' }, _('IP地址')),
            E('th', { 'class': 'th' }, _('在线时间')),
            E('th', { 'class': 'th' }, _('使用流量'))
        ])
    ]);
}

function updateStatus(table, accounts) {
    var rows = table.querySelectorAll('tr:not(.table-titles)');
    var rowMap = new Map();
    
    rows.forEach(row => {
        var iface = row.cells[0].textContent;
        rowMap.set(iface, row);
    });

    accounts.forEach(function(acc) {
        var row = rowMap.get(acc.interface);
        if (!row) {
            row = E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td' }, acc.interface || 'N/A'),
                E('td', { 'class': 'td' }, [
                    E('img', { 
                        'src': '/luci-static/resources/icons/loading.gif',
                        'style': 'width:16px;height:16px'
                    })
                ]),
                E('td', { 'class': 'td' }, '加载中...'),
                E('td', { 'class': 'td' }, '加载中...'),
                E('td', { 'class': 'td' }, '加载中...')
            ]);
            table.appendChild(row);
        }
        callGetStatus(acc.interface).then(function(result) {
            row.cells[1].innerHTML = '';
            row.cells[1].textContent = result?.uid || 'N/A';
            row.cells[2].textContent = result?.v4ip || 'N/A';
            row.cells[3].textContent = result?.time || 'N/A';
            row.cells[4].textContent = result?.flow || 'N/A';
        }).catch(function(e) {
            row.cells[1].innerHTML = '';
            row.cells[1].textContent = '错误';
            row.cells[2].textContent = 'N/A';
            row.cells[3].textContent = 'N/A';
            row.cells[4].textContent = 'N/A';
        });
    });

    var timestamp = document.getElementById('cquauth-timestamp');
    if (timestamp) {
        timestamp.textContent = _('最后更新: ') + new Date().toLocaleString();
    } else {
        table.parentNode.appendChild(E('div', { 'id': 'cquauth-timestamp' }, 
            _('最后更新: ') + new Date().toLocaleString()));
    }
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
        var interfaces = data[1].map(function(entry) { 
            return entry.name; 
        }).filter(function(iface) {
            return iface.match(/^eth/) || iface.match(/^wlan/);
        });
    
        m = new form.Map('cquauth', _('CQU Auth Client'), _('非官方重庆大学网络认证客户端'));

        // ================= 状态显示部分 =================
        s = m.section(form.NamedSection, '_status', 'status');
        s.title = _('状态');
        s.anonymous = true;
        s.render = function(section_id) {
            var container = E('div', { 
                'class': 'cbi-section', 
                'id': 'cquauth-status-section' 
            });
            
            var accounts = [];
            uci.sections('cquauth', 'account', function(s) {
                if (s.interface) {
                    accounts.push({
                        user: s.user,
                        interface: s.interface
                    });
                }
            });

            if (accounts.length === 0) {
                container.appendChild(E('div', { 'class': 'alert-message warning' }, 
                    _('没有配置任何账号')));
            } else {
                var table = createStatusTable();
                container.appendChild(table);

                if (!pollAdded) {
                    poll.add(function() {
                        var currentTable = document.querySelector('#cquauth-status-section .table');
                        if (currentTable) {
                            var currentAccounts = [];
                            uci.sections('cquauth', 'account', function(s) {
                                if (s.interface) {
                                    currentAccounts.push({
                                        user: s.user,
                                        interface: s.interface
                                    });
                                }
                            });
                            updateStatus(currentTable, currentAccounts);
                        }
                    }, 5);
                    pollAdded = true;
                }

                updateStatus(table, accounts);
            }
            
            return container;
        };

        // ================= 配置表单部分 =================
        s = m.section(form.TypedSection, 'basic', _('基本设置'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.Flag, 'enabled', _('启用服务'));
        o.default = '1';
        o.rmempty = false;
        o.description = _('修改配置后请手动重启服务');

        o = s.option(form.Value, 'ping_target', _('Ping目标'));
        o.default = '223.5.5.5';
        o.rmempty = false;

        o = s.option(form.Value, 'check_interval', _('检查间隔'));
        o.default = '60';
        o.rmempty = false;

        o = s.option(form.Value, 'max_attempts', _('最大尝试次数'));
        o.default = '0';
        o.rmempty = false;
        o.description = _('0表示无限重试');

        o = s.option(form.Flag, 'enable_ecmp', _('启用 ECMP'));
        o.default = '0';
        o.rmempty = false;
        o.description = _('启用后, 所有启用账号的接口都会启用ECMP, 并使用WAN ZONE接口自动故障转移');

        o = s.option(form.Value, 'ecmp_table', _('ECMP路由表'));
        o.default = 'main';
        o.rmempty = false;
        o.description = _('默认为main, 可自定义搭配ip rule使用');

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
