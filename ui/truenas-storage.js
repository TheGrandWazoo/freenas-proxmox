// TrueNAS Custom Storage Plugin — Proxmox VE UI
//
// Registers the 'truenas' storage type in PVE's UI schema and defines the
// configuration panel shown when adding or editing TrueNAS storage.
//
// Loaded by index.html.tpl after pvemanagerlib.js, so PVE.Utils is available.

// Inject CSS for the API key reveal trigger (eye icon via Font Awesome)
(function () {
    let style = document.createElement('style');
    style.textContent = [
        '.truenas-reveal-trigger::before {',
        '    font-family: "Font Awesome 5 Free";',
        '    font-weight: 900;',
        '    content: "\\f06e";',  // fa-eye
        '}',
    ].join('');
    document.head.appendChild(style);
}());

// Register TrueNAS in the storage type dropdown
PVE.Utils.storageSchema.truenas = {
    name: 'TrueNAS (ZFS/iSCSI)',
    ipanel: 'TrueNASInputPanel',
    faIcon: 'database',
    backups: false,
};

Ext.define('PVE.storage.TrueNASInputPanel', {
    extend: 'PVE.panel.StorageBase',

    initComponent: function () {
        let me = this;

        // Column 1 — identity and credentials (left side)
        me.column1 = [
            {
                xtype: me.isCreate ? 'proxmoxtextfield' : 'displayfield',
                fieldLabel: gettext('TrueNAS Host'),
                name: 'truenas_host',
                allowBlank: false,
                autoComplete: false,
                // 'url' misdirects browser autofill away from username heuristics
                inputAttrTpl: 'autocomplete="url"',
                emptyText: gettext('hostname or IP address'),
            },
            {
                xtype: 'proxmoxtextfield',
                fieldLabel: gettext('API Key'),
                name: 'truenas_api_key',
                inputType: 'password',
                allowBlank: !me.isCreate,
                autoComplete: false,
                // 'new-password' prevents browser from filling a saved password here
                inputAttrTpl: 'autocomplete="new-password"',
                emptyText: me.isCreate
                    ? gettext('Paste API key from TrueNAS UI')
                    : gettext('unchanged — paste new key to change'),
                triggers: {
                    reveal: {
                        cls: 'truenas-reveal-trigger',
                        tooltip: gettext('Show / hide API key'),
                        handler: function (field) {
                            let dom = field.inputEl.dom;
                            dom.type = dom.type === 'password' ? 'text' : 'password';
                        },
                    },
                },
                listeners: {
                    // On edit: don't submit unless the user types a new value
                    afterrender: function (field) {
                        if (!me.isCreate) {
                            field.submitValue = false;
                        }
                    },
                    change: function (field, value) {
                        if (!me.isCreate) {
                            field.submitValue = (value && value.length > 0);
                        }
                    },
                },
            },
            {
                xtype: me.isCreate ? 'proxmoxtextfield' : 'displayfield',
                fieldLabel: gettext('Pool / Dataset Path'),
                name: 'truenas_pool',
                allowBlank: false,
                autoComplete: false,
                emptyText: gettext('ZFS path where volumes live (e.g. tank or tank/proxmox/vdisks)'),
            },
            {
                xtype: 'proxmoxtextfield',
                fieldLabel: gettext('Sub-dataset'),
                name: 'truenas_dataset',
                allowBlank: true,
                autoComplete: false,
                emptyText: gettext('Leave blank — extra sub-path below Pool if needed'),
                deleteEmpty: !me.isCreate,
            },
        ];

        // Column 2 — connection options (right side)
        // Note: Nodes selector and Enable checkbox are prepended by StorageBase
        me.column2 = [
            {
                xtype: 'proxmoxcheckbox',
                fieldLabel: gettext('Use SSL'),
                name: 'truenas_ssl',
                checked: true,
                uncheckedValue: 0,
            },
            {
                xtype: 'proxmoxcheckbox',
                fieldLabel: gettext('Verify SSL Certificate'),
                name: 'truenas_ssl_verify',
                checked: false,
                uncheckedValue: 0,
            },
            {
                xtype: 'proxmoxtextfield',
                fieldLabel: gettext('Portal IP'),
                name: 'truenas_portal_ip',
                allowBlank: true,
                autoComplete: false,
                emptyText: gettext('Optional — defaults to TrueNAS host'),
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxtextfield',
                fieldLabel: gettext('Target IQN'),
                name: 'truenas_target',
                allowBlank: true,
                autoComplete: false,
                emptyText: gettext('Optional — auto-discovered if blank'),
                deleteEmpty: !me.isCreate,
            },
        ];

        me.callParent();
    },
});
