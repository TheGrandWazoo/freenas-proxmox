// TrueNAS Multipath Storage Plugin — Proxmox VE UI
//
// Registers the 'truenas-multipath' storage type in PVE's UI schema and defines
// the configuration panel shown when adding or editing TrueNAS Multipath storage.
//
// Only loaded on nodes where truenas-proxmox-multipath is installed, so the type
// does not appear in the Add dropdown on nodes without the package.

PVE.Utils.storageSchema['truenas-multipath'] = {
    name: 'TrueNAS Multipath (ZFS/iSCSI)',
    ipanel: 'TrueNASMultipathInputPanel',
    faIcon: 'database',
    backups: false,
};

Ext.define('PVE.storage.TrueNASMultipathInputPanel', {
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

        // Column 2 — connection and multipath options (right side)
        // Note: Nodes selector and Enable checkbox are prepended by StorageBase
        me.column2 = [
            {
                xtype: 'proxmoxcheckbox',
                fieldLabel: gettext('Shared'),
                name: 'shared',
                checked: true,
                uncheckedValue: 0,
            },
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
                fieldLabel: gettext('Portal IPs'),
                name: 'truenas_portals',
                allowBlank: false,
                autoComplete: false,
                emptyText: gettext('Comma-separated portal IPs (e.g. 172.31.x.x,192.168.x.x)'),
            },
        ];

        me.callParent();
    },
});
