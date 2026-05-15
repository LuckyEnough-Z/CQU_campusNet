'use strict';
'require view';

return view.extend({
    render: function() {
        var viewContainer = E('div');
        
        L.require('view/cquauth/cquauth').then(function(view) {
            return view.render();
        }).then(function(content) {
            viewContainer.appendChild(content);
        }).catch(function(e) {
            viewContainer.appendChild(E('div', { 'class': 'alert-message error' }, 
                _('加载失败: ') + e.message));
        });
        
        return viewContainer;
    }
});