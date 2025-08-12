// =======================================================================
// Mods for orchestrator panel - Updated with AFC support
// =======================================================================

PVE.Utils.sdnOrchestratorSchema = {
    'psm': { ipanel: 'PsmInputPanel', faIcon: 'microchip' },
    'afc': { ipanel: 'AfcInputPanel', faIcon: 'sitemap' },
};
PVE.Utils.format_sdnOrchestrator_type = (value) => {
    const types = {
        'psm': 'Pensando PSM',
        'afc': 'Aruba Fabric Composer'
    };
    return types[value] || value;
};

// Fixed base class for input panels
Ext.define('PVE.panel.SDNOrchestratorInputPanel', {
    extend: 'Proxmox.panel.InputPanel',
    
    onGetValues: function(values) {
        var me = this;
        
        if (me.isCreate) {
            values.type = me.type;
            // Remove any auto-generated widget IDs
            delete values.orchestrator;
            delete values['pveSdnOrchestratorEdit-1132']; // Remove any form widget IDs
            
            // Clean up any widget IDs that might have been added
            Object.keys(values).forEach(function(key) {
                if (key.startsWith('pveSdn') || key.startsWith('ext-')) {
                    delete values[key];
                }
            });
        }
        
        // Don't send empty password on edit
        if (!me.isCreate && values.password === '') {
            delete values.password;
        }
        
        // Convert comma-separated lists to arrays if needed
        ['reserved_vlans', 'reserved_vrf_names', 'reserved_zone_names', 'fabric_name'].forEach(function(key) {
            if (values[key] && typeof values[key] === 'string' && values[key].trim() !== '') {
                // Keep as string for backend - it will handle parsing
                values[key] = values[key].trim();
            } else if (values[key] === '') {
                delete values[key];  // Don't send empty strings
            }
        });
        
        return values;
    },
});

// PSM Input Panel
Ext.define('PVE.sdn.orchestrators.PsmInputPanel', {
    extend: 'PVE.panel.SDNOrchestratorInputPanel',
    xtype: 'pveSdnPsmInputPanel',
    
    initComponent: function() {
        var me = this;
        
        me.items = [
            {
                xtype: 'fieldset',
                title: gettext('Connection Settings'),
                collapsible: true,
                items: [
                    {
                        xtype: 'textfield',
                        name: 'host',
                        fieldLabel: 'PSM Host',
                        allowBlank: false,
                    },
                    {
                        xtype: 'numberfield',
                        name: 'port',
                        fieldLabel: gettext('Port'),
                        value: 443,
                        minValue: 1,
                        maxValue: 65535,
                        allowBlank: false,
                    },
                    {
                        xtype: 'textfield',
                        name: 'user',
                        fieldLabel: gettext('Username'),
                        allowBlank: false,
                    },
                    {
                        xtype: 'textfield',
                        name: 'password',
                        fieldLabel: gettext('Password'),
                        inputType: 'password',
                        allowBlank: this.isCreate, // Password optional on edit
                        emptyText: this.isCreate ? '' : gettext('Unchanged'),
                    },
                    {
                        xtype: 'proxmoxcheckbox',
                        name: 'verify_ssl',
                        fieldLabel: gettext('Verify SSL'),
                        checked: false,
                        uncheckedValue: 0,
                        inputValue: 1,
                    },
                ]
            },
            {
                xtype: 'fieldset',
                title: gettext('Operation Settings'),
                collapsible: true,
                items: [
                    {
                        xtype: 'proxmoxcheckbox',
                        name: 'enabled',
                        fieldLabel: gettext('Enabled'),
                        checked: true,
                        uncheckedValue: 0,
                        inputValue: 1,
                        boxLabel: gettext('Enable synchronization'),
                    },
                    {
                        xtype: 'numberfield',
                        name: 'poll_interval_seconds',
                        fieldLabel: gettext('Poll Interval'),
                        value: 60,
                        minValue: 10,
                        maxValue: 3600,
                        allowBlank: false,
                        afterLabelTextTpl: ' ' + gettext('seconds'),
                    },
                    {
                        xtype: 'numberfield',
                        name: 'request_timeout',
                        fieldLabel: gettext('Request Timeout'),
                        value: 10,
                        minValue: 5,
                        maxValue: 300,
                        allowBlank: false,
                        afterLabelTextTpl: ' ' + gettext('seconds'),
                    },
                ]
            },
            {
                xtype: 'fieldset',
                title: gettext('Reserved Resources'),
                collapsible: true,
                collapsed: true,
                items: [
                    {
                        xtype: 'textfield',
                        name: 'reserved_vlans',
                        fieldLabel: gettext('Reserved VLANs'),
                        emptyText: 'e.g., 1,100,200-300',
                        allowBlank: true,
                    },
                    {
                        xtype: 'textfield',
                        name: 'reserved_vrf_names',
                        fieldLabel: gettext('Reserved VRFs'),
                        emptyText: 'e.g., mgmt-vrf,system-vrf',
                        allowBlank: true,
                    },
                    {
                        xtype: 'textfield',
                        name: 'reserved_zone_names',
                        fieldLabel: gettext('Reserved Zones'),
                        emptyText: 'e.g., zone1,zone2',
                        allowBlank: true,
                    },
                ]
            },
        ];
        
        me.callParent();
    },
});

// NEW: AFC Input Panel (Simplified)
Ext.define('PVE.sdn.orchestrators.AfcInputPanel', {
    extend: 'PVE.panel.SDNOrchestratorInputPanel',
    xtype: 'pveSdnAfcInputPanel',
    
    initComponent: function() {
        var me = this;
        
        me.items = [
            {
                xtype: 'fieldset',
                title: gettext('Connection Settings'),
                collapsible: true,
                items: [
                    {
                        xtype: 'textfield',
                        name: 'host',
                        fieldLabel: 'AFC Host',
                        allowBlank: false,
                    },
                    {
                        xtype: 'numberfield',
                        name: 'port',
                        fieldLabel: gettext('Port'),
                        value: 443,
                        minValue: 1,
                        maxValue: 65535,
                        allowBlank: false,
                    },
                    {
                        xtype: 'textfield',
                        name: 'user',
                        fieldLabel: gettext('Username'),
                        allowBlank: false,
                    },
                    {
                        xtype: 'textfield',
                        name: 'password',
                        fieldLabel: gettext('Password'),
                        inputType: 'password',
                        allowBlank: this.isCreate, // Password optional on edit
                        emptyText: this.isCreate ? '' : gettext('Unchanged'),
                    },
                ]
            },
            {
                xtype: 'fieldset',
                title: gettext('Fabric Settings'),
                collapsible: true,
                items: [
                    {
                        xtype: 'textfield',
                        name: 'fabric_name',
                        fieldLabel: gettext('Fabric Names'),
                        emptyText: 'e.g., DC1,DC2,DC3',
                        allowBlank: true,
                    },
                ]
            },
            {
                xtype: 'fieldset',
                title: gettext('Operation Settings'),
                collapsible: true,
                items: [
                    {
                        xtype: 'proxmoxcheckbox',
                        name: 'enabled',
                        fieldLabel: gettext('Enabled'),
                        checked: true,
                        uncheckedValue: 0,
                        inputValue: 1,
                        boxLabel: gettext('Enable synchronization'),
                    },
                    {
                        xtype: 'proxmoxcheckbox',
                        name: 'verify_ssl',
                        fieldLabel: gettext('Verify SSL'),
                        checked: true,
                        uncheckedValue: 0,
                        inputValue: 1,
                        boxLabel: gettext('Verify SSL certificates'),
                    },
                    {
                        xtype: 'numberfield',
                        name: 'poll_interval_seconds',
                        fieldLabel: gettext('Poll Interval'),
                        value: 120,
                        minValue: 30,
                        maxValue: 3600,
                        allowBlank: false,
                        afterLabelTextTpl: ' ' + gettext('seconds'),
                    },
                    {
                        xtype: 'numberfield',
                        name: 'request_timeout',
                        fieldLabel: gettext('Request Timeout'),
                        value: 30,
                        minValue: 10,
                        maxValue: 300,
                        allowBlank: false,
                        afterLabelTextTpl: ' ' + gettext('seconds'),
                    },
                ]
            },
            {
                xtype: 'fieldset',
                title: gettext('Reserved Resources'),
                collapsible: true,
                collapsed: true,
                items: [
                    {
                        xtype: 'textfield',
                        name: 'reserved_vlans',
                        fieldLabel: gettext('Reserved VLANs'),
                        emptyText: 'e.g., 1,100,200-300',
                        allowBlank: true,
                    },
                    {
                        xtype: 'textfield',
                        name: 'reserved_vrf_names',
                        fieldLabel: gettext('Reserved VRFs'),
                        emptyText: 'e.g., mgmt-vrf,system-vrf',
                        allowBlank: true,
                    },
                ]
            },
        ];
        
        me.callParent();
    },
});

// The rest of your existing code remains the same...

Ext.define('PVE.sdn.OrchestratorEdit', {
    extend: 'Proxmox.window.Edit',
    xtype: 'pveSdnOrchestratorEdit',

        initComponent: function() {
        console.log('OrchestratorEdit initComponent called');
        var me = this;
        
        // Use orchestratorId instead of id to avoid confusion with widget ID
        var orchestratorId = me.orchestratorId;
        me.isCreate = !orchestratorId;
        var type = me.type;
        
        console.log('isCreate:', me.isCreate, 'orchestratorId:', orchestratorId, 'type:', type);
        
        // FIX: Use me.rec instead of me.getRecord()
        if (!me.isCreate && me.rec) {
            type = me.rec.data.type;
            console.log('Edit mode - got type from record:', type);
        }

        if (!type) { 
            console.error('No type specified for orchestrator');
            throw 'no type specified for orchestrator'; 
        }
        
        let schema = PVE.Utils.sdnOrchestratorSchema[type];
        console.log('Schema for type', type, ':', schema);
        
        if (!schema || !schema.ipanel) { 
            console.error('No editor registered for type:', type);
            throw 'no editor registered for orchestrator type: ' + type; 
        }
        
        var ipanel = Ext.create('PVE.sdn.orchestrators.' + schema.ipanel, {
            type: type,
            isCreate: me.isCreate,
            border: 0,
        });
        
        console.log('Created input panel:', schema.ipanel);

        // Store reference to input panel
        me.inputPanel = ipanel;

        if (me.isCreate) {
            me.url = '/api2/extjs/cluster/sdn/orchestrators';
            me.method = 'POST';
            console.log('Create mode - URL:', me.url);
        } else {
            me.url = '/api2/extjs/cluster/sdn/orchestrators/' + orchestratorId;
            me.method = 'PUT';
            console.log('Edit mode - URL:', me.url);
        }

        me.items = [
            {
                xtype: 'inputpanel',
                columnT: 2,
                items: [
                    {
                        xtype: 'textfield',
                        name: 'id',
                        fieldLabel: gettext('Name'),
                        value: orchestratorId || '',
                        allowBlank: false,
                        disabled: !me.isCreate,
                        regex: /^[a-zA-Z][a-zA-Z0-9\-_]*$/,
                        regexText: 'Name must start with a letter and contain only letters, numbers, hyphens, and underscores',
                        maxLength: 32,
                        listeners: {
                            change: function(field, newVal) {
                                console.log('ID field changed to:', newVal);
                            }
                        }
                    },
                    {
                        xtype: 'textfield',
                        name: 'description',
                        fieldLabel: gettext('Description'),
                        allowBlank: true,
                    },
                ],
            },
            ipanel,
        ];

        me.subject = PVE.Utils.format_sdnOrchestrator_type(type);
        me.width = 600;
        me.height = 550;

        // Override submit to add debugging
        me.submit = function() {
            console.log('Submit called');
            
            var form = me.formPanel.getForm();
            
            if (!form.isValid()) {
                console.log('Form is not valid');
                return;
            }
            
            var values = me.getValues();
            console.log('Values to submit:', JSON.stringify(values));
            
            if (!values.id && me.isCreate) {
                console.error('No ID provided for new orchestrator');
                Ext.Msg.alert('Error', 'Name field is required');
                return;
            }
            
            // AFC-specific validation
            if (type === 'afc' && me.isCreate) {
                if (!values.password) {
                    Ext.Msg.alert('Error', 'AFC orchestrator requires password');
                    return;
                }
            }
            
            // Log the actual request
            console.log('Submitting to URL:', me.url);
            console.log('Method:', me.method);
            console.log('Values:', values);
            
            // Call parent submit with our values
            Proxmox.window.Edit.prototype.submit.call(me);
        };

        // Override getValues to ensure correct handling
        me.getValues = function() {
            console.log('getValues called');
            var values = {};
            
            // Collect values from all panels
            me.items.each(function(item) {
                console.log('Checking item:', item.xtype);
                if (item.getValues) {
                    var itemValues = item.getValues();
                    console.log('Item values:', itemValues);
                    Ext.Object.merge(values, itemValues);
                }
            });
            
            // Also get values from the input panel directly
            if (me.inputPanel && me.inputPanel.getValues) {
                var panelValues = me.inputPanel.getValues();
                console.log('Input panel values:', panelValues);
                Ext.Object.merge(values, panelValues);
            }
            
            console.log('Raw collected values:', JSON.stringify(values));
            
            // Clean up the values
            if (me.isCreate) {
                values.type = type;
                console.log('Added type:', type);
                
                // Remove any ExtJS widget IDs
                var keysToDelete = [];
                Object.keys(values).forEach(function(key) {
                    if (key.indexOf('OrchestratorEdit') !== -1 || 
                        key.indexOf('ext-') === 0 ||
                        (key.indexOf('pve') === 0 && key !== 'id')) {
                        keysToDelete.push(key);
                    }
                });
                
                keysToDelete.forEach(function(key) {
                    console.log('Deleting key:', key);
                    delete values[key];
                });
            }
            
            // Convert checkboxes
            ['enabled', 'verify_ssl'].forEach(function(key) {
                if (values[key] !== undefined) {
                    var oldVal = values[key];
                    values[key] = values[key] ? 1 : 0;
                    console.log('Converted', key, 'from', oldVal, 'to', values[key]);
                }
            });
            
            // Handle password
            if (!me.isCreate) {
                if (values.password === '') {
                    console.log('Removing empty password for edit');
                    delete values.password;
                }
            }
            
            // Clean empty strings from optional fields
            ['reserved_vlans', 'reserved_vrf_names', 'reserved_zone_names', 'fabric_name'].forEach(function(key) {
                if (values[key] === '') {
                    console.log('Removing empty', key);
                    delete values[key];
                }
            });
            
            console.log('Final cleaned values:', JSON.stringify(values));
            
            return values;
        };

        me.callParent();
        console.log('OrchestratorEdit initialization complete');

        if (!me.isCreate) {
            console.log('Loading existing data for:', orchestratorId);
            me.load({
                success: function(response) {
                    console.log('Load success, data:', response.result.data);
                    var values = response.result.data;
                    
                    // Convert boolean values for checkboxes
                    ['enabled', 'verify_ssl'].forEach(function(key) {
                        if (values[key] !== undefined) {
                            // Convert 1/0 to true/false for checkboxes
                            values[key] = !!values[key];
                            console.log('Converted checkbox', key, 'to', values[key]);
                        }
                    });
                    
                    // Convert arrays to comma-separated strings for display
                    ['reserved_vlans', 'reserved_vrf_names', 'reserved_zone_names'].forEach(function(key) {
                        if (values[key] && Array.isArray(values[key])) {
                            console.log('Converting array', key, 'to string');
                            values[key] = values[key].join(',');
                        }
                    });
                    
                    console.log('Setting values:', values);
                    me.setValues(values);
                },
                failure: function(response) {
                    console.error('Load failed:', response);
                }
            });
        }
    },
});

Ext.define('PVE.sdn.OrchestratorView', {
    extend: 'Ext.grid.GridPanel', 
    alias: ['widget.pveSdnOrchestratorView'], 
    stateful: true, 
    stateId: 'grid-sdn-orchestrators',

    initComponent: function() {
        var me = this;
        
        var store = new Ext.data.Store({
            proxy: { 
                type: 'proxmox', 
                url: '/api2/json/cluster/sdn/orchestrators' 
            },
            autoLoad: true,  // Add autoLoad here
            sorters: { 
                property: 'id', 
                direction: 'ASC' 
            },
        });
        
        var sm = Ext.create('Ext.selection.RowModel', {});
        
        var run_editor = function() { 
            var rec = sm.getSelection()[0]; 
            if (rec) { 
                console.log('Editing orchestrator:', rec.data.id);
                Ext.create('PVE.sdn.OrchestratorEdit', {
                    orchestratorId: rec.data.id,  // Use orchestratorId instead of id
                    rec: rec, // pass full record
                    autoShow: true,
                    listeners: { 
                        destroy: function() { 
                            me.reload(); 
                        } 
                    },
                }).show();
            } 
        };
        
        var edit_btn = new Proxmox.button.Button({ 
            text: gettext('Edit'), 
            disabled: true, 
            selModel: sm, 
            handler: run_editor 
        });
        
        var remove_btn = Ext.create('Proxmox.button.StdRemoveButton', { 
            selModel: sm, 
            baseurl: '/cluster/sdn/orchestrators', 
            callback: function() { 
                store.load(); 
            }
        });
        
        var addHandleGenerator = function(type) {
            return function() {
                console.log('Creating new orchestrator of type:', type);
                Ext.create('PVE.sdn.OrchestratorEdit', {
                    type: type,
                    orchestratorId: undefined,  // Explicitly no ID for create
                    autoShow: true,
                    listeners: { 
                        destroy: function() { 
                            me.reload(); 
                        } 
                    },
                }).show();
            };
        };
        
        var addMenuItems = [];
        for (const [type, schema] of Object.entries(PVE.Utils.sdnOrchestratorSchema)) { 
            addMenuItems.push({ 
                text: PVE.Utils.format_sdnOrchestrator_type(type), 
                iconCls: 'fa fa-fw fa-' + schema.faIcon, 
                handler: addHandleGenerator(type) 
            }); 
        }
        
        Ext.apply(me, {
            store: store, 
            reload: function() { 
                store.load(); 
            }, 
            selModel: sm,
            tbar: [ 
                { text: gettext('Add'), menu: new Ext.menu.Menu({ items: addMenuItems }) }, 
                remove_btn, 
                edit_btn 
            ],
            columns: [ 
                { header: gettext('Name'), flex: 2, dataIndex: 'id' }, 
                { header: gettext('Type'), flex: 1, dataIndex: 'type', renderer: PVE.Utils.format_sdnOrchestrator_type }, 
                { 
                    header: gettext('Status'), 
                    width: 100, 
                    dataIndex: 'enabled',
                    renderer: function(value) {
                        var icon = value ? 'fa-check-circle good' : 'fa-times-circle critical';
                        var text = value ? gettext('Enabled') : gettext('Disabled');
                        return '<i class="fa ' + icon + '"></i> ' + text;
                    }
                },
                { header: gettext('Host'), flex: 2, dataIndex: 'host' }, 
                { header: gettext('Description'), flex: 3, dataIndex: 'description', renderer: Ext.String.htmlEncode }
            ],
            listeners: { 
                activate: function() { 
                    console.log('OrchestratorView activated, loading store');
                    store.load(); 
                }, 
                itemdblclick: run_editor,
                show: function() {
                    console.log('OrchestratorView shown, loading store');
                    store.load();
                },
                afterrender: function() {
                    console.log('OrchestratorView rendered, loading store');
                    store.load();
                }
            },
        });
        
        me.callParent();
        
        // Force initial load if store is empty
        if (store.getCount() === 0) {
            console.log('Store empty on init, loading...');
            store.load();
        }
    },
});
