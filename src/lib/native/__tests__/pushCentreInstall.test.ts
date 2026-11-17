/**
 * PN4 push centre — the build step that puts the rich push service into the
 * app (scripts/android-native-plugins.mjs), and what the app tells the server
 * it can show — see pushRegisterCaps.test.ts.
 *
 * The Android project is generated in CI (`npx cap add android`), so the
 * installer is proven here against a temp project shaped like Capacitor's.
 * The plugin's build.gradle line is the real one from
 * @capacitor-firebase/messaging 8.4.0 (the version android-build.yml pins).
 */
import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  installPushCentre,
  pushManifest,
  pluginFirebaseVersion,
  PACKAGE_DIR,
  PLUGIN_PUSH_SERVICE,
  PUSH_SERVICE,
} from "../../../../scripts/android-native-plugins.mjs";

const ROOT = path.resolve(__dirname, "../../../..");

const MANIFEST = `<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <application
        android:allowBackup="true"
        android:label="@string/app_name">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>

    <uses-permission android:name="android.permission.INTERNET" />
</manifest>
`;

/** Line 6 of @capacitor-firebase/messaging 8.4.0 android/build.gradle, verbatim. */
const PLUGIN_GRADLE = `ext {
    junitVersion = project.hasProperty('junitVersion') ? rootProject.ext.junitVersion : '4.13.2'
    firebaseMessagingVersion = project.hasProperty('firebaseMessagingVersion') ? rootProject.ext.firebaseMessagingVersion : '25.0.1'
}
`;

function project({ withPlugin = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pn4-android-"));
  fs.mkdirSync(path.join(dir, PACKAGE_DIR), { recursive: true });
  fs.writeFileSync(path.join(dir, "app", "src", "main", "AndroidManifest.xml"), MANIFEST);
  fs.writeFileSync(path.join(dir, "app", "build.gradle"), "apply plugin: 'com.android.application'\n");
  fs.writeFileSync(
    path.join(dir, "capacitor.settings.gradle"),
    withPlugin
      ? "include ':capacitor-firebase-messaging'\nproject(':capacitor-firebase-messaging').projectDir = new File('../node_modules/@capacitor-firebase/messaging/android')\n"
      : "include ':capacitor-app'\n",
  );
  const pluginGradle = path.join(dir, "plugin-build.gradle");
  fs.writeFileSync(pluginGradle, PLUGIN_GRADLE);
  return { dir, pluginGradle };
}

const snapshot = (dir: string) => {
  const out: Record<string, string> = {};
  const walk = (d: string) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else out[path.relative(dir, p)] = fs.readFileSync(p, "utf8");
    }
  };
  walk(dir);
  return out;
};

describe("pushManifest — ONE service receives pushes", () => {
  const out = pushManifest(MANIFEST);
  it("removes the plugin's service and names PushRichService for MESSAGING_EVENT", () => {
    expect(out).toContain(`<service android:name="${PLUGIN_PUSH_SERVICE}" tools:node="remove" />`);
    expect(out).toContain(`<service android:name="${PUSH_SERVICE}" android:exported="false">`);
    expect(out.match(/com\.google\.firebase\.MESSAGING_EVENT/g)).toHaveLength(1);
    expect(out).toMatch(/<manifest xmlns:android="[^"]+" xmlns:tools="http:\/\/schemas\.android\.com\/tools">/);
    // the service block sits inside <application>, and the rest is untouched
    expect(out.indexOf(PUSH_SERVICE)).toBeLessThan(out.indexOf("</application>"));
    expect(out).toContain('<uses-permission android:name="android.permission.INTERNET" />');
  });
  it("is idempotent", () => {
    expect(pushManifest(out)).toBe(out);
  });
  it("refuses a manifest it cannot place the service in safely", () => {
    expect(() => pushManifest(MANIFEST.replace("</application>", "</application></application>"))).toThrow(/exactly one/);
    expect(() => pushManifest(MANIFEST.replace('xmlns:android="http://schemas.android.com/apk/res/android"', ""))).toThrow(/root/);
    const half = out.replace(` tools:node="remove"`, "");
    expect(() => pushManifest(half)).toThrow(/two services/);
  });
});

describe("pluginFirebaseVersion — the plugin's own Firebase version", () => {
  it("reads 25.0.1 from the 8.4.0 build.gradle line", () => {
    expect(pluginFirebaseVersion(PLUGIN_GRADLE)).toBe("25.0.1");
  });
  it("stops the build when the line changes shape", () => {
    expect(() => pluginFirebaseVersion("firebaseMessagingVersion = '1.0'")).toThrow(/shape changed/);
  });
});

describe("installPushCentre — into a generated Android project", () => {
  it("copies the classes and layouts, patches the manifest and Gradle; a second run changes nothing", () => {
    const { dir, pluginGradle } = project();
    const done = installPushCentre(dir, { pluginGradle });
    for (const c of ["PushRichService", "PushRichNotifier"]) {
      expect(fs.existsSync(path.join(dir, PACKAGE_DIR, `${c}.java`))).toBe(true);
    }
    const res = path.join(dir, "app", "src", "main", "res", "layout");
    expect(fs.existsSync(path.join(res, "push_rich_big.xml"))).toBe(true);
    expect(fs.existsSync(path.join(res, "push_rich_slide.xml"))).toBe(true);
    const manifest = fs.readFileSync(path.join(dir, "app", "src", "main", "AndroidManifest.xml"), "utf8");
    expect(manifest.match(/com\.google\.firebase\.MESSAGING_EVENT/g)).toHaveLength(1);
    const gradle = fs.readFileSync(path.join(dir, "app", "build.gradle"), "utf8");
    expect(gradle).toContain("com.google.firebase:firebase-messaging:");
    expect(gradle).toContain("'25.0.1'");
    expect(done.join("\n")).toMatch(/firebase-messaging 25\.0\.1/);

    const before = snapshot(dir);
    installPushCentre(dir, { pluginGradle });
    expect(snapshot(dir)).toEqual(before);
  });

  it("refuses a build without the push plugin, a missing project, and a clashing layout", () => {
    const a = project({ withPlugin: false });
    expect(() => installPushCentre(a.dir, { pluginGradle: a.pluginGradle })).toThrow(/not in capacitor\.settings\.gradle/);
    expect(() => installPushCentre(path.join(os.tmpdir(), "no-such-android-dir"))).toThrow(/not found/);
    const b = project();
    const layout = path.join(b.dir, "app", "src", "main", "res", "layout");
    fs.mkdirSync(layout, { recursive: true });
    fs.writeFileSync(path.join(layout, "push_rich_big.xml"), "<other/>");
    expect(() => installPushCentre(b.dir, { pluginGradle: b.pluginGradle })).toThrow(/refusing to overwrite/);
  });

  it("PushRichService extends the plugin's service class (the one the manifest removes)", () => {
    const java = fs.readFileSync(path.join(ROOT, "resources/android/java/com/fiftymmretina/app/PushRichService.java"), "utf8");
    expect(java).toContain(`import ${PLUGIN_PUSH_SERVICE};`);
    expect(java).toMatch(/public class PushRichService extends MessagingService\b/);
    expect(java).toContain("super.onMessageReceived(message);"); // every other push still reaches the plugin
  });
});
