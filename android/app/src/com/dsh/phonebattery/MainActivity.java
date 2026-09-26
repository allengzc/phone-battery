package com.dsh.phonebattery;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * One screen: asks for the Bluetooth/notification permissions, then starts
 * {@link BatteryGattService}, which advertises this phone as a standard BLE
 * Battery Service peripheral.
 *
 * There is nothing to configure — the service is the whole product.
 */
public class MainActivity extends Activity {

    private static final int REQ = 0x8B1;

    private TextView status;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(56, 96, 56, 56);

        TextView title = new TextView(this);
        title.setText("Phone Battery over Bluetooth LE");
        title.setTextSize(21f);
        title.setTextColor(Color.BLACK);
        root.addView(title);

        status = new TextView(this);
        status.setTextSize(15f);
        status.setPadding(0, 32, 0, 0);
        status.setTextColor(Color.DKGRAY);
        root.addView(status);

        TextView hint = new TextView(this);
        hint.setTextSize(13f);
        hint.setPadding(0, 40, 0, 0);
        hint.setTextColor(Color.GRAY);
        hint.setText("This app does nothing on its own. It makes the phone advertise a "
                + "standard Bluetooth LE Battery Service (0x180F / 0x2A19) so a computer can "
                + "read this phone's battery level. Keep it running (a persistent "
                + "notification appears) while you want the level visible.\n\n"
                + "No network access, no storage, no analytics.");
        root.addView(hint);

        setContentView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        root.setGravity(Gravity.TOP);

        requestNeededPermissions();
    }

    private String[] missingPermissions() {
        List<String> needed = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
                    != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.BLUETOOTH_ADVERTISE);
            }
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
                    != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.BLUETOOTH_CONNECT);
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS);
        }
        return needed.toArray(new String[0]);
    }

    private void requestNeededPermissions() {
        String[] needed = missingPermissions();
        if (needed.length == 0) {
            startService();
            return;
        }
        status.setText("Grant the permissions to start advertising.");
        requestPermissions(needed, REQ);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode != REQ) return;
        String[] stillMissing = missingPermissions();
        boolean bluetoothDenied = false;
        for (String p : stillMissing) {
            if (p.contains("BLUETOOTH")) bluetoothDenied = true;
        }
        if (bluetoothDenied) {
            status.setText("Bluetooth permission denied — advertising cannot start. "
                    + "Grant it, then reopen this app.");
            return;
        }
        startService();
    }

    private void startService() {
        Intent intent = new Intent(this, BatteryGattService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
        status.setText("Advertising as a Battery Service.\n\nIf your computer does not show a "
                + "battery yet, make sure the phone is paired to it and give it a few seconds.");
    }
}
