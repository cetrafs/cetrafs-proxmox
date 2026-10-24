// Proxmox VE web UI integration for the 'cetrafs' storage type
// (package pve-storage-cetrafs-ui).
//
// Loaded by index.html.tpl right after pvemanagerlib.js, before the workspace
// is created, so the storage type is registered before Datacenter -> Storage
// builds its "Add" menu. Without this file the storage still works, it just
// shows as "Unknown" and can only be managed with pvesm.
//
// Everything here is optional: if pve-manager changed in a way we do not
// understand, log and leave the UI alone rather than break it.

// No 'use strict' here: ExtJS's callParent() needs arguments.callee.caller,
// which strict mode forbids.
(function() {
    if (typeof Ext === 'undefined' || typeof PVE === 'undefined' ||
	!PVE.Utils || !PVE.Utils.storageSchema ||
	!Ext.ClassManager.get('PVE.panel.StorageBase') ||
	!Ext.ClassManager.get('PVE.form.FileSelector')) {
	if (typeof console !== 'undefined') {
	    console.warn('cetrafs-ui: unsupported pve-manager version, UI integration disabled');
	}
	return;
    }

    if (Ext.ClassManager.get('PVE.storage.CetraFSInputPanel')) {
	return; // loaded twice
    }

    // Same rule as is_unstable_device_path() in CetraFSPlugin.pm.
    const UNSTABLE_DEVICE = /^\/dev\/(?:[shv]d[a-z]+|xvd[a-z]+|dm-\d+|nvme\d+n\d+)(?:p?\d+)?$/;

    try {
	Ext.define('PVE.storage.CetraFSIScsiSelector', {
	    extend: 'Ext.form.field.ComboBox',
	    alias: 'widget.pveCetraFSIScsiSelector',

	    queryMode: 'local',
	    editable: false,
	    valueField: 'storage',
	    displayField: 'storage',
	    listConfig: {
		emptyText: gettext('No iSCSI storage configured'),
	    },

	    initComponent: function() {
		let me = this;

		me.store = Ext.create('Ext.data.Store', {
		    autoLoad: true,
		    fields: ['storage', 'type'],
		    sorters: 'storage',
		    proxy: {
			type: 'proxmox',
			url: '/api2/json/storage',
			extraParams: { type: 'iscsi' },
		    },
		});

		me.callParent();
	    },
	});

	Ext.define('PVE.storage.CetraFSInputPanel', {
	    extend: 'PVE.panel.StorageBase',

	    initComponent: function() {
		let me = this;

		me.column1 = [];

		if (me.isCreate) {
		    let lunField = Ext.createWidget('pveFileSelector', {
			name: 'base',
			fieldLabel: gettext('LUN'),
			nodename: 'localhost',
			storageContent: 'images',
			allowBlank: false,
		    });

		    let iscsiField = Ext.createWidget('pveCetraFSIScsiSelector', {
			fieldLabel: gettext('iSCSI storage'),
			submitValue: false,
			allowBlank: false,
			listeners: {
			    change: function(f, value) {
				lunField.clearValue();
				if (value) {
				    lunField.setStorage(value);
				}
			    },
			},
		    });

		    let deviceField = Ext.createWidget('textfield', {
			name: 'cetrafs-device',
			fieldLabel: gettext('Device'),
			emptyText: '/dev/disk/by-id/... or /dev/mapper/...',
			hidden: true,
			disabled: true,
			allowBlank: false,
			validator: function(value) {
			    if (UNSTABLE_DEVICE.test(value)) {
				return 'Kernel names like /dev/sdX or /dev/dm-N differ between'
				    + ' nodes and boots - use /dev/disk/by-id/... or /dev/mapper/<name>';
			    }
			    if (value && value.indexOf('/dev/') !== 0) {
				return gettext('Must be a path below /dev/');
			    }
			    return true;
			},
		    });

		    me.column1.push(
			{
			    xtype: 'proxmoxKVComboBox',
			    fieldLabel: gettext('Source'),
			    submitValue: false,
			    value: 'base',
			    comboItems: [
				['base', 'iSCSI LUN'],
				['device', 'Block device'],
			    ],
			    listeners: {
				change: function(f, value) {
				    let isBase = value === 'base';
				    iscsiField.setVisible(isBase);
				    iscsiField.setDisabled(!isBase);
				    lunField.setVisible(isBase);
				    lunField.setDisabled(!isBase);
				    deviceField.setVisible(!isBase);
				    deviceField.setDisabled(isBase);
				},
			    },
			},
			iscsiField,
			lunField,
			deviceField,
		    );
		} else {
		    // Only one of the two is set; show that one.
		    let showIfSet = {
			change: function(f, value) {
			    f.setHidden(!value);
			},
		    };
		    me.column1.push(
			{
			    xtype: 'displayfield',
			    name: 'base',
			    htmlEncode: true,
			    fieldLabel: gettext('LUN'),
			    hidden: true,
			    listeners: showIfSet,
			},
			{
			    xtype: 'displayfield',
			    name: 'cetrafs-device',
			    htmlEncode: true,
			    fieldLabel: gettext('Device'),
			    hidden: true,
			    listeners: showIfSet,
			},
		    );
		}

		me.column1.push(
		    {
			xtype: me.isCreate ? 'proxmoxtextfield' : 'displayfield',
			name: 'path',
			htmlEncode: !me.isCreate,
			fieldLabel: gettext('Mount point'),
			emptyText: '/mnt/pve/<ID>',
		    },
		    {
			xtype: 'pveContentTypeSelector',
			name: 'content',
			value: ['images', 'rootdir'],
			multiSelect: true,
			fieldLabel: gettext('Content'),
			allowBlank: false,
		    },
		);

		me.column2 = [
		    {
			xtype: 'displayfield',
			fieldLabel: gettext('Shared'),
			value: Proxmox.Utils.yesText,
		    },
		    {
			xtype: 'proxmoxtextfield',
			name: 'options',
			fieldLabel: gettext('Mount options'),
			emptyText: 'nofilelock (always added)',
			deleteEmpty: !me.isCreate,
		    },
		];

		me.callParent();
	    },
	});

	PVE.Utils.storageSchema.cetrafs = {
	    name: 'CetraFS',
	    ipanel: 'CetraFSInputPanel',
	    faIcon: 'database',
	    backups: true,
	};
    } catch (err) {
	if (typeof console !== 'undefined') {
	    console.error('cetrafs-ui: UI integration disabled:', err);
	}
    }
})();
