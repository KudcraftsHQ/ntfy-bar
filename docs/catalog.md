# Server catalog (Kudcrafts ntfy fork)

On a server running the Kudcrafts fork with `enable-catalog`, ntfy-bar lists every topic you can
read without you adding any by hand. On stock ntfy the catalog endpoint returns 404 and nothing changes.

## Sign in

Settings › Server: enter the server URL, username and password, then **Sign In**. ntfy-bar calls
`POST /v1/account/token` with label `ntfy-bar-<computer name>`, stores the token in the Keychain and
deletes the password. Revoke it from the web app (Account › Access tokens).

## Sync

`GET /v1/catalog` (with `If-None-Match`) runs on launch, on wake, after sign-in or a server change,
on every stream (re)connect, every 15 minutes, and within seconds of a `{"event":"sync"}` message on
the account's sync topic. That topic is added to the stream but never shown or stored.

Reconcile rules (only on HTTP 200):

- A topic the catalog lists and you don't have is added, **synced**, on and unmuted, and its last 7 days are
  loaded into the list without notifying.
- A topic you already have gets the catalog's app, icon, name and sound; your on/off and mute stay.
- A synced topic the catalog stops listing (access revoked, topic deleted) is removed.
- Topics the catalog doesn't know are left alone.

Synced topics can be turned off or muted, not removed. Switch the whole thing off with
Settings › Catalog › "Sync topics from the server" (default: on, except for ntfy.sh).

## Sounds

| Class | macOS |
|---|---|
| `silent` | no sound |
| `default` | system notification sound |
| `alert` | `kc_alert.caf` |
| `urgent` | `kc_urgent.caf`, time-sensitive |

Priority 1–2 messages are always quiet. Topics the catalog doesn't know keep the old rule (sound for
priority 4–5, or for everything with "Play sound for every message"). The two `.caf` files are
placeholders synthesized with ffmpeg; replace them in `Sources/NtfyBar/Resources/Sounds/`.
Time-sensitive delivery needs an entitlement that ad-hoc builds lack, so macOS may treat urgent like alert.
