#!/usr/bin/env node
/**
 * Copies this repository's own Capacitor plugins into the GENERATED Android
 * project (android/ is not committed; `npx cap add android` makes it in CI)
 * and registers them in MainActivity.
 *
 *   node scripts/android-native-plugins.mjs android
 *
 * Today: ExitInfoPlugin (S2 native crash / OOM / ANR reasons) and the push
 * centre (PN4, Owner 16 Nov 2026): PushCentrePlugin + PushRichService /
 * PushRichNotifier (live countdown, buttons, picture slides) with its layouts,
 * its manifest entry and the one Gradle line it needs — see installPushCentre.
 *
 * Everything the app build needs for these lives HERE, not in
 * android-build.yml: a change to that workflow file on main starts an app
 * build, and the Owner builds once, at the end of a task.
 *
 * Guarded, not a blind sed: MainActivity must be EXACTLY Capacitor's template
 * (`public class MainActivity extends BridgeActivity {}`) or already carry our
 * registration. Anything else stops the build with a message, because a
 * plugin that is copied but not registered is undefined at runtime with every
 * test green (known trap #11).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const PACKAGE_DIR = "app/src/main/java/com/fiftymmretina/app";
export const PLUGINS = ["ExitInfoPlugin", "PushCentrePlugin"];
const SOURCE_DIR = path.join(HERE, "..", "resources", "android", "java", "com", "fiftymmretina", "app");

// ── push centre (PN4) ───────────────────────────────────────────────────────
/** Plain classes: copied beside the plugins, not registered (they are not Capacitor plugins). */
export const PUSH_CLASSES = ["PushRichService", "PushRichNotifier"];
export const PUSH_SERVICE = "com.fiftymmretina.app.PushRichService";
export const PLUGIN_PUSH_SERVICE = "io.capawesome.capacitorjs.plugins.firebase.messaging.MessagingService";
const RES_DIR = path.join(HERE, "..", "resources", "android", "res");
const PUSH_PLUGIN_GRADLE = path.join(HERE, "..", "node_modules", "@capacitor-firebase", "messaging", "android", "build.gradle");
const GRADLE_MARKER = "// PN4 push centre";

const TEMPLATE_BODY = /public class MainActivity extends BridgeActivity \{\s*\}/;

export function registeredMainActivity(pkg, plugins) {
  const regs = plugins.map((p) => `        registerPlugin(${p}.class);`).join("\n");
  return `package ${pkg};

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // Local plugins must be registered BEFORE super.onCreate builds the bridge.
${regs}
        super.onCreate(savedInstanceState);
    }
}
`;
}

/** Returns a list of what it did; throws with a reason when the project is not what it expects. */
export function installNativePlugins(androidDir, { sourceDir = SOURCE_DIR, plugins = PLUGINS } = {}) {
  const done = [];
  const pkgDir = path.join(androidDir, PACKAGE_DIR);
  const mainPath = path.join(pkgDir, "MainActivity.java");
  if (!fs.existsSync(mainPath)) {
    throw new Error(`${mainPath} not found — did \`npx cap add android\` run, and is the appId still com.fiftymmretina.app?`);
  }
  for (const p of plugins) {
    const src = path.join(sourceDir, `${p}.java`);
    if (!fs.existsSync(src)) throw new Error(`plugin source ${src} not found`);
    fs.copyFileSync(src, path.join(pkgDir, `${p}.java`));
    done.push(`copied ${p}.java`);
  }
  const main = fs.readFileSync(mainPath, "utf8");
  const pkg = (main.match(/^package\s+([\w.]+);/m) || [])[1];
  if (pkg !== "com.fiftymmretina.app") throw new Error(`MainActivity package is ${pkg ?? "(none)"}, expected com.fiftymmretina.app`);
  const already = plugins.every((p) => main.includes(`registerPlugin(${p}.class);`));
  if (already) {
    done.push("MainActivity already registers every plugin");
  } else if (TEMPLATE_BODY.test(main)) {
    fs.writeFileSync(mainPath, registeredMainActivity(pkg, plugins));
    done.push(`MainActivity registers ${plugins.join(", ")}`);
  } else {
    throw new Error(
      "MainActivity is not Capacitor's template and does not register our plugins — refusing to guess. " +
        "Update scripts/android-native-plugins.mjs for the new template.",
    );
  }
  const after = fs.readFileSync(mainPath, "utf8");
  for (const p of plugins) {
    if (!after.includes(`registerPlugin(${p}.class);`)) throw new Error(`MainActivity does not register ${p}`);
    if (after.indexOf(`registerPlugin(${p}.class);`) > after.indexOf("super.onCreate(")) {
      throw new Error(`${p} is registered after super.onCreate — the bridge would not see it`);
    }
  }
  return done;
}

/**
 * The manifest with OUR push service in charge. Android hands a push to ONE
 * service: the plugin's entry is removed (tools:node) and PushRichService —
 * which extends it — takes com.google.firebase.MESSAGING_EVENT.
 * Pure: text in, text out. Already patched → returned unchanged.
 */
export function pushManifest(xml) {
  if (xml.includes(PUSH_SERVICE)) {
    if (!xml.includes(`android:name="${PLUGIN_PUSH_SERVICE}" tools:node="remove"`)) {
      throw new Error("AndroidManifest names PushRichService but does not remove the plugin's service — two services would claim pushes");
    }
    return xml;
  }
  if ((xml.match(/<\/application>/g) || []).length !== 1) {
    throw new Error("AndroidManifest does not hold exactly one </application> — refusing to guess where the service goes");
  }
  const root = xml.match(/<manifest\b[^>]*>/);
  if (!root || !/xmlns:android="http:\/\/schemas\.android\.com\/apk\/res\/android"/.test(root[0])) {
    throw new Error("AndroidManifest root is not Capacitor's <manifest xmlns:android=…> — refusing to guess");
  }
  let out = xml;
  if (!/\bxmlns:tools=/.test(root[0])) {
    out = out.replace(root[0], root[0].replace(/xmlns:android="[^"]*"/, (m) => `${m} xmlns:tools="http://schemas.android.com/tools"`));
  }
  const block = `
        <!-- PN4 push centre: one service receives pushes. PushRichService extends the
             plugin's service and draws rich admin pushes; everything else it passes on. -->
        <service android:name="${PLUGIN_PUSH_SERVICE}" tools:node="remove" />
        <service android:name="${PUSH_SERVICE}" android:exported="false">
            <intent-filter>
                <action android:name="com.google.firebase.MESSAGING_EVENT" />
            </intent-filter>
        </service>
    </application>`;
  return out.replace(/\s*<\/application>/, block);
}

/** The Firebase Messaging version the push plugin itself builds with (its build.gradle default). */
export function pluginFirebaseVersion(pluginGradle) {
  const m = /firebaseMessagingVersion\s*=\s*project\.hasProperty\('firebaseMessagingVersion'\)\s*\?\s*rootProject\.ext\.firebaseMessagingVersion\s*:\s*'([0-9][0-9A-Za-z.-]*)'/.exec(pluginGradle);
  if (!m) throw new Error("could not read firebaseMessagingVersion from the push plugin's build.gradle — its shape changed");
  return m[1];
}

/**
 * The Gradle lines appended to app/build.gradle. PushRichService extends the
 * plugin's service, whose parent class is Firebase's; the plugin keeps
 * Firebase as its own `implementation` dependency, which the app module cannot
 * see when compiling. Same version as the plugin, so nothing else resolves
 * differently.
 */
export function pushGradleBlock(version) {
  return `
${GRADLE_MARKER}: PushRichService extends the push plugin's service (Firebase's class).
dependencies {
    implementation "com.google.firebase:firebase-messaging:\${rootProject.ext.has('firebaseMessagingVersion') ? rootProject.ext.firebaseMessagingVersion : '${version}'}"
}
`;
}

function copyTree(from, to, done, rel = "") {
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const src = path.join(from, entry.name);
    const dst = path.join(to, entry.name);
    const name = rel ? `${rel}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      fs.mkdirSync(dst, { recursive: true });
      copyTree(src, dst, done, name);
    } else {
      const bytes = fs.readFileSync(src);
      if (fs.existsSync(dst) && !fs.readFileSync(dst).equals(bytes)) {
        throw new Error(`res/${name} already exists in the Android project with other content — refusing to overwrite`);
      }
      fs.writeFileSync(dst, bytes);
      done.push(`copied res/${name}`);
    }
  }
}

/**
 * Push centre (PN4): classes, layouts, manifest entry, Gradle line.
 * Idempotent; throws with a reason when the project is not what it expects.
 * Run AFTER installNativePlugins (PushCentrePlugin is registered there).
 */
export function installPushCentre(androidDir, { sourceDir = SOURCE_DIR, resDir = RES_DIR, pluginGradle = PUSH_PLUGIN_GRADLE } = {}) {
  const done = [];
  const pkgDir = path.join(androidDir, PACKAGE_DIR);
  const manifestPath = path.join(androidDir, "app", "src", "main", "AndroidManifest.xml");
  const gradlePath = path.join(androidDir, "app", "build.gradle");
  const settingsPath = path.join(androidDir, "capacitor.settings.gradle");
  for (const p of [pkgDir, manifestPath, gradlePath, settingsPath]) {
    if (!fs.existsSync(p)) throw new Error(`${p} not found — did \`npx cap add android\` run?`);
  }
  // PushRichService extends the plugin's class: without the plugin in this build it cannot compile.
  if (!fs.readFileSync(settingsPath, "utf8").includes("capacitor-firebase-messaging")) {
    throw new Error("the push plugin (@capacitor-firebase/messaging) is not in capacitor.settings.gradle — PushRichService cannot build without it");
  }
  if (!fs.existsSync(pluginGradle)) throw new Error(`${pluginGradle} not found — is @capacitor-firebase/messaging installed?`);

  for (const c of PUSH_CLASSES) {
    const src = path.join(sourceDir, `${c}.java`);
    if (!fs.existsSync(src)) throw new Error(`class source ${src} not found`);
    fs.copyFileSync(src, path.join(pkgDir, `${c}.java`));
    done.push(`copied ${c}.java`);
  }

  const resOut = path.join(androidDir, "app", "src", "main", "res");
  fs.mkdirSync(resOut, { recursive: true });
  copyTree(resDir, resOut, done);

  const manifest = fs.readFileSync(manifestPath, "utf8");
  const patched = pushManifest(manifest);
  if (patched !== manifest) {
    fs.writeFileSync(manifestPath, patched);
    done.push("AndroidManifest: PushRichService receives pushes (plugin service removed)");
  } else {
    done.push("AndroidManifest already names PushRichService");
  }

  const gradle = fs.readFileSync(gradlePath, "utf8");
  if (gradle.includes(GRADLE_MARKER)) {
    done.push("app/build.gradle already has the Firebase Messaging line");
  } else {
    const version = pluginFirebaseVersion(fs.readFileSync(pluginGradle, "utf8"));
    fs.writeFileSync(gradlePath, gradle.replace(/\s*$/, "\n") + pushGradleBlock(version));
    done.push(`app/build.gradle: firebase-messaging ${version} (the plugin's own version)`);
  }

  // Prove it, from the files as they now are.
  const after = fs.readFileSync(manifestPath, "utf8");
  if ((after.match(/com\.google\.firebase\.MESSAGING_EVENT/g) || []).length !== 1 || !after.includes(`android:name="${PUSH_SERVICE}"`)) {
    throw new Error("AndroidManifest does not name exactly one service for MESSAGING_EVENT after the patch");
  }
  if (!fs.existsSync(path.join(resOut, "layout", "push_rich_big.xml")) || !fs.existsSync(path.join(resOut, "layout", "push_rich_slide.xml"))) {
    throw new Error("push layouts are missing from the Android project — PushRichNotifier would not compile");
  }
  return done;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dir = process.argv[2] || "android";
  try {
    for (const line of installNativePlugins(dir)) console.log(`OK: ${line}`);
    for (const line of installPushCentre(dir)) console.log(`OK: ${line}`);
  } catch (e) {
    console.error(`::error::${e.message}`);
    process.exit(1);
  }
}
