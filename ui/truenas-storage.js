// TrueNAS Custom Storage Plugin — Proxmox VE UI
//
// Registers the 'truenas' storage type in PVE's UI schema and defines the
// configuration panel shown when adding or editing TrueNAS storage.
//
// Loaded by index.html.tpl after pvemanagerlib.js, so PVE.Utils is available.

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
                emptyText: gettext('hostname or IP address'),
            },
            {
                xtype: 'proxmoxtextfield',
                fieldLabel: gettext('API Key'),
                name: 'truenas_api_key',
                inputType: 'password',
                allowBlank: !me.isCreate,
                emptyText: me.isCreate
                    ? gettext('Paste API key from TrueNAS UI')
                    : gettext('unchanged — paste new key to change'),
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
                fieldLabel: gettext('Pool'),
                name: 'truenas_pool',
                allowBlank: false,
                emptyText: gettext('ZFS pool name (e.g. tank)'),
            },
            {
                xtype: 'proxmoxtextfield',
                fieldLabel: gettext('Dataset'),
                name: 'truenas_dataset',
                allowBlank: true,
                emptyText: gettext('Optional (e.g. proxmox)'),
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
                emptyText: gettext('Optional — defaults to TrueNAS host'),
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxtextfield',
                fieldLabel: gettext('Target IQN'),
                name: 'truenas_target',
                allowBlank: true,
                emptyText: gettext('Optional — auto-discovered if blank'),
                deleteEmpty: !me.isCreate,
            },
        ];

        me.callParent();
    },
});
