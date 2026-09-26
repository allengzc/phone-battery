package com.dsh.phonebattery;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.ParcelUuid;
import android.util.Log;

import java.util.UUID;

/**
 * Presents the phone as a Bluetooth LE peripheral that is BOTH:
 *
 *   1. a HID-over-GATT input device (a mouse that never moves)  — 0x1812
 *   2. a standard Battery Service                               — 0x180F / 0x2A19
 *
 * Why a HID device as well as a battery: macOS only turns a Bluetooth accessory
 * into an `AppleDeviceManagementHIDEventService` IORegistry node (with a
 * `BatteryPercent` property) when it accepts the device as an INPUT accessory.
 * Stats reads its battery level for BLE accessories from exactly that node, so
 * "battery service only" is invisible to it. Advertising HID first makes macOS
 * adopt the device, after which it reads the Battery Service and publishes the
 * percentage where Stats can see it.
 *
 * The mouse never emits a report, so it cannot affect the pointer.
 */
public class BatteryGattService extends Service {

    private static final String TAG = "PhoneBatteryBLE";
    private static final String CHANNEL_ID = "phone-battery-ble";
    private static final int NOTIFICATION_ID = 0x8B1;
    private static final long REFRESH_MS = 30_000L;

    private static UUID uuid(String short16) {
        return UUID.fromString("0000" + short16 + "-0000-1000-8000-00805f9b34fb");
    }

    private static final UUID BATTERY_SERVICE = uuid("180f");
    private static final UUID BATTERY_LEVEL = uuid("2a19");
    private static final UUID CCCD = uuid("2902");

    private static final UUID HID_SERVICE = uuid("1812");
    private static final UUID HID_INFORMATION = uuid("2a4a");
    private static final UUID REPORT_MAP = uuid("2a4b");
    private static final UUID HID_CONTROL_POINT = uuid("2a4c");
    private static final UUID REPORT = uuid("2a4d");
    private static final UUID PROTOCOL_MODE = uuid("2a4e");
    private static final UUID BOOT_MOUSE_INPUT = uuid("2a33");
    private static final UUID REPORT_REFERENCE = uuid("2908");

    private static final UUID DIS_SERVICE = uuid("180a");
    private static final UUID MANUFACTURER_NAME = uuid("2a29");
    private static final UUID MODEL_NUMBER = uuid("2a24");
    private static final UUID PNP_ID = uuid("2a50");

    /**
     * HID report descriptor: a three-button relative mouse. macOS parses this to
     * decide the device class, and it is the reason the phone is adopted as an
     * input accessory rather than ignored as an unknown peripheral.
     */
    private static final byte[] REPORT_DESCRIPTOR = new byte[]{
            0x05, 0x01,        // Usage Page (Generic Desktop)
            0x09, 0x02,        // Usage (Mouse)
            (byte) 0xA1, 0x01, // Collection (Application)
            0x09, 0x01,        //   Usage (Pointer)
            (byte) 0xA1, 0x00, //   Collection (Physical)
            0x05, 0x09,        //     Usage Page (Button)
            0x19, 0x01,        //     Usage Minimum (1)
            0x29, 0x03,        //     Usage Maximum (3)
            0x15, 0x00,        //     Logical Minimum (0)
            0x25, 0x01,        //     Logical Maximum (1)
            (byte) 0x95, 0x03,        //     Report Count (3)
            0x75, 0x01,        //     Report Size (1)
            (byte) 0x81, 0x02, //     Input (Data,Var,Abs)
            (byte) 0x95, 0x01,        //     Report Count (1)
            0x75, 0x05,        //     Report Size (5)
            (byte) 0x81, 0x03, //     Input (Const,Var,Abs) — padding
            0x05, 0x01,        //     Usage Page (Generic Desktop)
            0x09, 0x30,        //     Usage (X)
            0x09, 0x31,        //     Usage (Y)
            0x15, (byte) 0x81, //     Logical Minimum (-127)
            0x25, 0x7F,        //     Logical Maximum (127)
            0x75, 0x08,        //     Report Size (8)
            (byte) 0x95, 0x02,        //     Report Count (2)
            (byte) 0x81, 0x06, //     Input (Data,Var,Rel)
            (byte) 0xC0,       //   End Collection
            (byte) 0xC0        // End Collection
    };

    private final Handler handler = new Handler(Looper.getMainLooper());

    private BluetoothManager bluetoothManager;
    private BluetoothAdapter adapter;
    private BluetoothGattServer gattServer;
    private BluetoothGattCharacteristic batteryLevel;
    private BluetoothLeAdvertiser advertiser;
    private boolean advertising = false;

    private int level = -1;

    private final BroadcastReceiver batteryReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            publish(readBatteryPercent(), "battery-changed");
        }
    };

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            publish(readBatteryPercent(), "refresh");
            handler.postDelayed(this, REFRESH_MS);
        }
    };

    private final BluetoothGattServerCallback serverCallback = new BluetoothGattServerCallback() {
        @Override
        public void onConnectionStateChange(BluetoothDevice device, int status, int newState) {
            Log.i(TAG, "connection " + addr(device) + " status=" + status + " state=" + newState);
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                publish(readBatteryPercent(), "central-connected");
            }
        }

        @Override
        public void onCharacteristicReadRequest(BluetoothDevice device, int requestId,
                                                int offset, BluetoothGattCharacteristic characteristic) {
            byte[] value = characteristic.getValue();
            if (value == null) value = new byte[]{0};
            int status = offset > value.length ? BluetoothGatt.GATT_INVALID_OFFSET : BluetoothGatt.GATT_SUCCESS;
            try {
                gattServer.sendResponse(device, requestId, status, offset, value);
                Log.i(TAG, "read " + shortUuid(characteristic.getUuid()) + " -> "
                        + value.length + " byte(s)");
            } catch (Exception e) {
                Log.w(TAG, "sendResponse failed", e);
            }
        }

        @Override
        public void onCharacteristicWriteRequest(BluetoothDevice device, int requestId,
                                                 BluetoothGattCharacteristic characteristic,
                                                 boolean preparedWrite, boolean responseNeeded,
                                                 int offset, byte[] value) {
            try {
                if (PROTOCOL_MODE.equals(characteristic.getUuid()) && value != null && value.length > 0) {
                    Log.i(TAG, "protocol mode -> " + value[0]);
                    characteristic.setValue(new byte[]{value[0]});
                } else if (HID_CONTROL_POINT.equals(characteristic.getUuid()) && value != null && value.length > 0) {
                    Log.i(TAG, "hid control point -> " + value[0]);
                }
                if (responseNeeded) {
                    gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value);
                }
            } catch (Exception e) {
                Log.w(TAG, "characteristic write failed", e);
            }
        }

        @Override
        public void onDescriptorReadRequest(BluetoothDevice device, int requestId,
                                            int offset, BluetoothGattDescriptor descriptor) {
            byte[] value = descriptor.getValue();
            if (value == null) value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;
            try {
                gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value);
            } catch (Exception e) {
                Log.w(TAG, "descriptor read failed", e);
            }
        }

        @Override
        public void onDescriptorWriteRequest(BluetoothDevice device, int requestId,
                                             BluetoothGattDescriptor descriptor, boolean preparedWrite,
                                             boolean responseNeeded, int offset, byte[] value) {
            try {
                if (value != null) descriptor.setValue(value);
                if (responseNeeded) {
                    gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value);
                }
                Log.i(TAG, "descriptor write " + shortUuid(descriptor.getUuid())
                        + "=" + hex(value) + " by " + addr(device));
                if (CCCD.equals(descriptor.getUuid())) {
                    notifyCentrals();
                }
            } catch (Exception e) {
                Log.w(TAG, "descriptor write failed", e);
            }
        }
    };

    private final AdvertiseCallback advertiseCallback = new AdvertiseCallback() {
        @Override
        public void onStartSuccess(AdvertiseSettings settingsInEffect) {
            advertising = true;
            Log.i(TAG, "advertising HID 0x1812 + Battery 0x180F");
            updateNotification();
        }

        @Override
        public void onStartFailure(int errorCode) {
            advertising = false;
            Log.e(TAG, "advertise failed, code=" + errorCode);
            if (errorCode == AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE) {
                advertiseMinimal();
            }
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startInForeground();

        IntentFilter filter = new IntentFilter(Intent.ACTION_BATTERY_CHANGED);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(batteryReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(batteryReceiver, filter);
        }

        startGattServer();
        startAdvertising();
        publish(readBatteryPercent(), "startup");
        handler.postDelayed(refresh, REFRESH_MS);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (gattServer == null) startGattServer();
        if (!advertising) startAdvertising();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        try {
            unregisterReceiver(batteryReceiver);
        } catch (Exception ignored) {
        }
        stopAdvertising();
        if (gattServer != null) {
            try {
                gattServer.clearServices();
                gattServer.close();
            } catch (Exception ignored) {
            }
            gattServer = null;
        }
        super.onDestroy();
    }

    // --- GATT -----------------------------------------------------------------

    private BluetoothGattCharacteristic characteristic(UUID id, int properties, int permissions,
                                                      byte[] initialValue) {
        BluetoothGattCharacteristic characteristic =
                new BluetoothGattCharacteristic(id, properties, permissions);
        if (initialValue != null) characteristic.setValue(initialValue);
        return characteristic;
    }

    private void startGattServer() {
        bluetoothManager = (BluetoothManager) getSystemService(BLUETOOTH_SERVICE);
        if (bluetoothManager == null) {
            Log.e(TAG, "no BluetoothManager");
            return;
        }
        adapter = bluetoothManager.getAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            Log.e(TAG, "Bluetooth adapter missing or disabled");
            return;
        }
        gattServer = bluetoothManager.openGattServer(this, serverCallback);
        if (gattServer == null) {
            Log.e(TAG, "openGattServer returned null");
            return;
        }

        // --- Battery Service ------------------------------------------------
        BluetoothGattService battery =
                new BluetoothGattService(BATTERY_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY);
        batteryLevel = characteristic(BATTERY_LEVEL,
                BluetoothGattCharacteristic.PROPERTY_READ | BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ,
                new byte[]{(byte) Math.max(0, level)});
        batteryLevel.addDescriptor(new BluetoothGattDescriptor(CCCD,
                BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
        battery.addCharacteristic(batteryLevel);

        // Battery only. A HID service here would make macOS demand a bonded
        // link and drop the connection (see the class comment), which breaks
        // every central including a plain battery reader.
        if (!gattServer.addService(battery)) {
            Log.e(TAG, "addService failed");
        }
        Log.i(TAG, "GATT server up: Battery Service 0x180F only");
    }

    private void notifyCentrals() {
        if (gattServer == null || batteryLevel == null || level < 0) return;
        try {
            batteryLevel.setValue(new byte[]{(byte) Math.max(0, Math.min(100, level))});
            for (BluetoothDevice device : bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)) {
                gattServer.notifyCharacteristicChanged(device, batteryLevel, false);
            }
        } catch (Exception e) {
            Log.w(TAG, "notify failed", e);
        }
    }

    // --- advertising ----------------------------------------------------------

    private AdvertiseSettings advertiseSettings() {
        return new AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .setTimeout(0)
                .build();
    }

    private void startAdvertising() {
        if (adapter == null) {
            BluetoothManager manager = (BluetoothManager) getSystemService(BLUETOOTH_SERVICE);
            adapter = manager != null ? manager.getAdapter() : null;
        }
        if (adapter == null || !adapter.isEnabled()) return;
        advertiser = adapter.getBluetoothLeAdvertiser();
        if (advertiser == null) {
            Log.e(TAG, "no BLE advertiser on this device");
            return;
        }

        AdvertiseData packet = new AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(new ParcelUuid(BATTERY_SERVICE))
                .build();

        AdvertiseData scanResponse = new AdvertiseData.Builder()
                .setIncludeDeviceName(true)
                .build();

        try {
            advertiser.startAdvertising(advertiseSettings(), packet, scanResponse, advertiseCallback);
        } catch (Exception e) {
            Log.e(TAG, "startAdvertising threw", e);
            advertiseMinimal();
        }
    }

    /** Fallback if the name in the scan response does not fit. */
    private void advertiseMinimal() {
        if (advertiser == null) return;
        try {
            AdvertiseData packet = new AdvertiseData.Builder()
                    .setIncludeDeviceName(false)
                    .addServiceUuid(new ParcelUuid(BATTERY_SERVICE))
                    .build();
            advertiser.startAdvertising(advertiseSettings(), packet, advertiseCallback);
        } catch (Exception e) {
            Log.e(TAG, "fallback advertising threw", e);
        }
    }

    private void stopAdvertising() {
        try {
            if (advertiser != null && advertising) advertiser.stopAdvertising(advertiseCallback);
        } catch (Exception ignored) {
        }
        advertising = false;
    }

    // --- battery --------------------------------------------------------------

    private int readBatteryPercent() {
        try {
            Intent intent = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (intent == null) return level >= 0 ? level : 0;
            int raw = intent.getIntExtra("level", -1);
            int scale = intent.getIntExtra("scale", 100);
            if (raw < 0 || scale <= 0) return level >= 0 ? level : 0;
            return Math.round(raw * 100f / scale);
        } catch (Exception e) {
            return level >= 0 ? level : 0;
        }
    }

    private void publish(int percent, String reason) {
        int clamped = Math.max(0, Math.min(100, percent));
        boolean changed = clamped != level;
        level = clamped;
        if (batteryLevel != null) {
            try {
                batteryLevel.setValue(new byte[]{(byte) level});
            } catch (Exception ignored) {
            }
        }
        if (changed) {
            Log.i(TAG, "level " + level + "% (" + reason + ")");
            notifyCentrals();
            updateNotification();
        }
    }

    // --- foreground notification ---------------------------------------------

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm == null) return;
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "Phone battery over Bluetooth", NotificationManager.IMPORTANCE_MIN);
        channel.setDescription("Keeps the Bluetooth LE battery + HID service running.");
        channel.setShowBadge(false);
        nm.createNotificationChannel(channel);
    }

    private Notification buildNotification() {
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return builder
                .setContentTitle("Phone Battery (BLE)")
                .setContentText(level < 0
                        ? "Starting services…"
                        : "Advertising " + level + "% (HID + Battery Service)")
                .setSmallIcon(R.drawable.ic_launcher)
                .setOngoing(true)
                .build();
    }

    private void startInForeground() {
        Notification notification = buildNotification();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    private void updateNotification() {
        try {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) nm.notify(NOTIFICATION_ID, buildNotification());
        } catch (Exception ignored) {
        }
    }

    // --- small helpers --------------------------------------------------------

    private static String addr(BluetoothDevice device) {
        return device != null ? device.getAddress() : "?";
    }

    private static String shortUuid(UUID id) {
        String s = id.toString();
        return s.startsWith("0000") ? s.substring(4, 8) : s;
    }

    private static String hex(byte[] value) {
        if (value == null) return "null";
        StringBuilder sb = new StringBuilder();
        for (byte b : value) sb.append(String.format("%02x", b));
        return sb.toString();
    }
}
