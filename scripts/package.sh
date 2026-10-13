#!/usr/bin/env bash
# Собирает IPA из xcarchive. Если заданы секреты подписи — подписывает вашим сертификатом и профилями,
# иначе делает IPA с «фейковой» подписью ldid (entitlements внутри), которую потом переподписывают Feather/Sideloadly.
set -euo pipefail

APP_SRC="build/Orbit.xcarchive/Products/Applications/Orbit.app"
APPEX_REL="PlugIns/OrbitTunnel.appex"
rm -rf Payload && mkdir Payload
cp -R "$APP_SRC" Payload/Orbit.app
APP="Payload/Orbit.app"
APPEX="$APP/$APPEX_REL"

APP_GROUP=$(grep -E '^\s+APP_GROUP_ID:' project.yml | head -1 | awk '{print $2}')

if [[ -n "${CERT_P12_BASE64:-}" && -n "${APP_PROFILE_BASE64:-}" && -n "${TUNNEL_PROFILE_BASE64:-}" ]]; then
  echo "== Подпись сертификатом разработчика =="
  KC="$RUNNER_TEMP/orbit.keychain-db"; KCPASS="orbit-ci"
  security create-keychain -p "$KCPASS" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPASS" "$KC"
  echo "$CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
  security import "$RUNNER_TEMP/cert.p12" -k "$KC" -P "${CERT_PASSWORD:-}" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  IDENTITY=$(security find-identity -v -p codesigning "$KC" | awk 'NR==1{print $2}')
  [[ -n "$IDENTITY" ]] || { echo "Сертификат для подписи не найден в p12"; exit 1; }

  sign_one() { # $1=bundle path  $2=profile base64
    local bundle="$1" prof="$RUNNER_TEMP/$(basename "$1").mobileprovision"
    echo "$2" | base64 --decode > "$prof"
    security cms -D -i "$prof" > "$prof.plist"
    /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$prof.plist" > "$prof.ent.plist"
    cp "$prof" "$bundle/embedded.mobileprovision"
    codesign -f -s "$IDENTITY" --entitlements "$prof.ent.plist" --timestamp=none "$bundle"
  }
  sign_one "$APPEX" "$TUNNEL_PROFILE_BASE64"
  sign_one "$APP" "$APP_PROFILE_BASE64"
  OUT="Orbit-signed.ipa"
else
  echo "== Секретов подписи нет: IPA с ldid (переподписать Feather/Sideloadly) =="
  gen_ent() { sed "s/\$(APP_GROUP_ID)/$APP_GROUP/g" "$1" > "$2"; }
  gen_ent Tunnel/OrbitTunnel.entitlements "$RUNNER_TEMP/tunnel.ent"
  gen_ent App/Orbit.entitlements "$RUNNER_TEMP/app.ent"
  ldid -S"$RUNNER_TEMP/tunnel.ent" "$APPEX/OrbitTunnel"
  ldid -S"$RUNNER_TEMP/app.ent" "$APP/Orbit"
  OUT="Orbit-unsigned.ipa"
fi

zip -qry "$OUT" Payload
ls -lh "$OUT"
