package com.dosboxx.app;

import android.app.Activity;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Per-game gamepad-to-keyboard keymap editor.
 *
 * Opened from the launcher's long-press menu. Loads the saved keymap (or the
 * built-in defaults) and shows one row per gamepad button (A, B, X, Y, L1,
 * R1, START, SELECT, D-pad). Tapping "Rebind" puts the editor in
 * capture-next-key mode; the very next physical key the user presses becomes
 * the binding for that slot. "Reset to defaults" wipes the saved file. "Done"
 * saves and finishes.
 */
public class KeyMapEditorActivity extends Activity {

    public static final String EXTRA_GAME_NAME = "gameName";

    private String gameName;
    private Map<String, Integer> map;       // current edits, mutable
    private Map<String, TextView> labels;   // button -> row label
    private String capturingFor = null;    // button name currently being rebound
    private EditText captureField;          // hidden field that owns key focus
    private TextView hint;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        gameName = getIntent().getStringExtra(EXTRA_GAME_NAME);
        if (gameName == null) gameName = "(unknown)";

        Map<String, Integer> saved = KeyMapStore.load(this, gameName);
        map = (saved != null) ? new LinkedHashMap<>(saved) : KeyMapStore.newDefaultMap();

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xFF101418);
        int pad = dp(12);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Controls — " + gameName);
        title.setTextColor(0xFFFFFFFF);
        title.setTextSize(20);
        root.addView(title);

        hint = new TextView(this);
        hint.setTextColor(0xFF80A0B0);
        hint.setTextSize(12);
        hint.setPadding(0, dp(4), 0, dp(8));
        root.addView(hint);

        ScrollView scroll = new ScrollView(this);
        LinearLayout rows = new LinearLayout(this);
        rows.setOrientation(LinearLayout.VERTICAL);
        labels = new LinkedHashMap<>();
        for (String btn : KeyMapStore.BUTTONS) rows.addView(makeRow(btn));
        scroll.addView(rows);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(scroll, slp);

        // Hidden field used as the key-focus target. We don't show the IME;
        // dispatchKeyEvent on this activity is what actually receives keys.
        captureField = new EditText(this);
        captureField.setInputType(InputType.TYPE_NULL);
        captureField.setImeOptions(EditorInfo.IME_ACTION_NONE);
        captureField.setFocusable(true);
        captureField.setFocusableInTouchMode(true);
        captureField.setVisibility(View.INVISIBLE);  // INVISIBLE keeps focus working; GONE would not
        captureField.setOnKeyListener((v, keyCode, event) -> {
            if (capturingFor == null) return false;
            if (event.getAction() != KeyEvent.ACTION_DOWN) return true;
            int kc = event.getKeyCode();
            // Esc cancels the rebind without changing the current value.
            if (kc == KeyEvent.KEYCODE_BACK) {
                capturingFor = null;
                setHint("Cancelled.");
                clearFocus();
                return true;
            }
            map.put(capturingFor, kc);
            String label = KeyMapStore.keycodeLabel(kc);
            labels.get(capturingFor).setText(capturingFor + "  →  " + label);
            setHint("Bound " + capturingFor + " to " + label + ".");
            capturingFor = null;
            clearFocus();
            return true;
        });
        root.addView(captureField, new LinearLayout.LayoutParams(0, 0));

        // Footer
        LinearLayout footer = new LinearLayout(this);
        footer.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        flp.topMargin = dp(8);
        Button reset = new Button(this);
        reset.setText("Reset");
        reset.setOnClickListener(v -> {
            KeyMapStore.clear(this, gameName);
            map.clear();
            map.putAll(KeyMapStore.newDefaultMap());
            refreshAllLabels();
            setHint("Reset to defaults (not yet saved).");
        });
        LinearLayout.LayoutParams h1 = new LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        h1.rightMargin = dp(6);
        footer.addView(reset, h1);

        Button done = new Button(this);
        done.setText("Done");
        done.setOnClickListener(v -> {
            boolean ok = KeyMapStore.save(this, gameName, map);
            Toast.makeText(this, ok ? "Saved." : "Save failed.", Toast.LENGTH_SHORT).show();
            finish();
        });
        LinearLayout.LayoutParams h2 = new LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        h2.leftMargin = dp(6);
        footer.addView(done, h2);
        root.addView(footer, flp);

        setContentView(root);
        refreshAllLabels();
    }

    private View makeRow(String button) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        int pad = dp(6);
        row.setPadding(0, pad, 0, pad);

        TextView label = new TextView(this);
        label.setTextColor(0xFFE0E0E0);
        label.setTextSize(16);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        row.addView(label, llp);
        labels.put(button, label);

        Button rebind = new Button(this);
        rebind.setText("Rebind");
        rebind.setOnClickListener(v -> {
            capturingFor = button;
            setHint("Press a key for " + button + " (Esc to cancel)...");
            captureField.requestFocus();
        });
        row.addView(rebind);

        return row;
    }

    private void refreshAllLabels() {
        for (Map.Entry<String, TextView> e : labels.entrySet()) {
            Integer v = map.get(e.getKey());
            String lbl = (v == null) ? "(none)" : KeyMapStore.keycodeLabel(v.intValue());
            e.getValue().setText(e.getKey() + "  →  " + lbl);
        }
    }

    private void setHint(String s) { hint.setText(s); }

    private void clearFocus() {
        View cur = getCurrentFocus();
        if (cur != null) cur.clearFocus();
    }

    @Override
    public void onBackPressed() {
        if (capturingFor != null) {
            capturingFor = null;
            setHint("Cancelled.");
            clearFocus();
            return;
        }
        super.onBackPressed();
    }

    private int dp(int v) { return (int) (v * getResources().getDisplayMetrics().density); }
}
