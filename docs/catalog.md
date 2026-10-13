# Server catalog (Kudcrafts ntfy fork)

On a server running the Kudcrafts fork with `enable-catalog`, ntfy-bar lists every topic you can
read without you adding any by hand. On stock ntfy the catalog endpoint returns 404 and nothing changes.

## Sign in

Settings › Server: enter the server URL, username and password, then **Sign In**. ntfy-bar calls
`POST /v1/account/token` with label `ntfy-bar-<computer name>` and `expires: 0` (never expires),
stores the token in the Keychain and deletes the password. Revoke it from the web app
(Account › Access tokens). When the server answers 401 (token revoked, user deleted), the popover
shows "Signed out" and Settings opens once, asking you to sign in again.

## Sync

`GET /v1/catalog` (with `If-None-Match`) runs on launch, on wake, after sign-in or a server change,
on every stream (re)connect, every 15 minutes, and within seconds of a `{"event":"sync"}` message on
the account's sync topic. That topic is added to the stream but never shown or stored.

Reconcile rules (only on HTTP 200):

- A topic the catalog lists and you don't have is added, **synced**, on and unmuted, and its last 7 days are
  loaded into the list without notifying.
- A topic you already have gets the catalog's app, icon, name and sound; your on/off and mute stay.
  If the catalog stops listing a topic you added yourself, it stays, without that metadata.
- A synced topic the catalog stops listing (access revoked, topic deleted) is removed.
- Topics the catalog doesn't know are left alone.

Synced topics can be turned off or muted, not removed. Switch the whole thing off with
Settings › Catalog › "Sync topics from the server" (default: on, except for ntfy.sh).

## Sounds

Every catalog topic has a sound class, and every class has a clip in each of ten bundled themes
(`Sources/NtfyBar/Resources/Sounds/kc_<theme>_<sound>.caf`, 70 clips; `build.sh` copies them into
`Contents/Resources`, and the app copies them to `~/Library/Sounds` on launch, where
`UNNotificationSound(named:)` finds them).

| Class | Meaning |
|---|---|
| `silent` | no sound |
| `default` | ordinary message |
| `alert` | look at this soon |
| `urgent` | prod broken, money at risk; time-sensitive |
| `cash` | order paid |
| `done` | job or agent finished |
| `fail` | build, deploy or job failed |
| `ask` | an agent needs an answer |

Themes: `wood`, `glass`, `soft`, `chip`, `pluck`, `keys`, `space`, `cabin`, `cockpit`, `terminal`.
The theme is this Mac's choice in **Settings › Notifications › Sound theme** if one is picked there,
else the server's `sound_theme` from `/v1/catalog`, else `cabin` (also for a server that sends none,
or an unknown name). The buttons under the picker play each clip of the theme.

Unknown classes are treated as `default`. Priority 1–2 messages are always quiet. Topics the catalog
doesn't know keep the old rule (system sound for priority 4–5, or for everything with "Play sound for
every message"). The clips are synthesized; their source is `docs/kudcrafts/sounds/` in the ntfy
server repo.
